defmodule Cadence.Daemon.Discovery do
  @moduledoc """
  Registers the direct child directories of a configured projects root (the
  hub) as Cadence projects.

  The hub is a discovery boundary, not a project. Each child gets the normal
  `{CommitQueue, Watcher}` pair through `Projects.register_project/2`, so commit
  and sync behavior is unchanged. Only direct children are considered: nested
  directories are part of their parent project, and a candidate that overlaps
  an existing project in either direction is skipped.

  Configuration:

    * `CAD_PROJECTS_ROOT` — the hub path; unset/empty disables discovery.
    * `CAD_PROJECTS_ROOT_SCAN_MS` — fallback rescan interval (default 30 s).

  Hidden entries (`.foo`) are skipped. A missing hub is logged once and retried;
  the daemon keeps running. Deleting or renaming a hub child does not delete its
  project: the existing watcher reconnects when the path returns, and a renamed
  directory registers as a new project.
  """

  use GenServer

  require Logger

  alias Cadence.Daemon.{
    CommitQueue,
    Env,
    Importer,
    ProjectLocation,
    ProjectRegistry,
    Projects,
    Repo
  }

  alias Cadence.Shared.{GitStore, Project}

  @reconnect_ms 1_000
  @max_slug_suffix 1_000

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Runs an immediate scan and waits for it (used by tests)."
  @spec scan_now(GenServer.server()) :: :ok
  def scan_now(server \\ __MODULE__), do: GenServer.call(server, :scan, 30_000)

  @doc "Queues a scan without blocking the caller (used after boot rehydration)."
  @spec scan_later(GenServer.server()) :: :ok
  def scan_later(server \\ __MODULE__) do
    send(server, :scan)
    :ok
  end

  @doc "Normalizes a directory basename into a project slug."
  @spec slugify(String.t()) :: String.t()
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "project"
      slug -> slug
    end
  end

  @impl true
  def init(opts) do
    case Keyword.get(opts, :root, Env.projects_root()) do
      root when is_binary(root) and root != "" ->
        Process.flag(:trap_exit, true)

        state = %{
          root: Path.expand(root),
          backend:
            Keyword.get(
              opts,
              :backend,
              Application.get_env(:cadence_daemon, :watch_backend, :fs_inotify)
            ),
          interval: Keyword.get(opts, :interval),
          scan_interval_ms: Keyword.get(opts, :scan_interval_ms, Env.projects_scan_interval_ms()),
          worker: nil,
          scan_timer: nil,
          reconnect_timer: nil,
          ready: false,
          warned: MapSet.new()
        }

        {:ok, open_backend(state)}

      _other ->
        :ignore
    end
  end

  @impl true
  def handle_call(:scan, _from, state) do
    state = state |> Map.put(:ready, true) |> scan() |> schedule_scan()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:file_event, worker, {path, _events}}, %{worker: worker} = state)
      when worker != nil do
    state =
      if state.ready and direct_child?(state.root, path) and File.dir?(path) do
        register_path(state, path)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:file_event, worker, :stop}, %{worker: worker} = state) when worker != nil do
    {:noreply, state}
  end

  # Late events from a backend that already died.
  def handle_info({:file_event, _worker, _event}, state), do: {:noreply, state}

  def handle_info({:EXIT, worker, reason}, %{worker: worker} = state) when worker != nil do
    state =
      state
      |> Map.put(:worker, nil)
      |> warn_once({:backend, reason}, "projects root watcher exited: #{inspect(reason)}")
      |> schedule_reconnect()

    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:reconnect, %{worker: nil} = state) do
    {:noreply, %{state | reconnect_timer: nil} |> open_backend()}
  end

  def handle_info(:reconnect, state), do: {:noreply, state}

  def handle_info(:scan, state) do
    {:noreply, state |> Map.put(:ready, true) |> scan() |> schedule_scan()}
  end

  @impl true
  def terminate(_reason, %{worker: worker}) when is_pid(worker) do
    Process.exit(worker, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Scanning and registration

  defp scan(state) do
    if File.dir?(state.root) do
      case File.ls(state.root) do
        {:ok, names} ->
          names
          |> Enum.sort()
          |> Enum.reduce(state, fn name, acc ->
            path = Path.join(acc.root, name)

            if hidden?(name) or not File.dir?(path) do
              acc
            else
              register_path(acc, path)
            end
          end)

        {:error, reason} ->
          warn_once(
            state,
            {:list, reason},
            "cannot list projects root #{state.root}: #{inspect(reason)}"
          )
      end
    else
      warn_once(
        state,
        :missing,
        "projects root #{state.root} is not a directory; retrying every #{@reconnect_ms} ms"
      )
    end
  end

  defp register_path(state, path) do
    cond do
      registered?(path) ->
        state

      overlap = overlap(path) ->
        warn_once(
          state,
          {:overlap, path},
          "skipping #{path}: overlaps registered project #{overlap}"
        )

      true ->
        name = Path.basename(path)
        slug = unique_slug(slugify(name))

        if git_repository?(path) do
          maybe_submit_import(state, path, name, slug)
        else
          register_plain(state, path, name, slug)
        end
    end
  end

  # A repository under the hub keeps its history: the existing importer copies
  # the refs and commits, stamps every imported node, and starts the watcher for
  # a worktree. A plain directory gets one imported snapshot of its current
  # tree and then the normal watcher path.
  defp maybe_submit_import(state, path, name, slug) do
    if import_active?(path) do
      state
    else
      try do
        case Task.Supervisor.start_child(Cadence.Daemon.ImportTasks, fn ->
               submit_import(path, name, slug)
             end) do
          {:ok, _pid} ->
            Logger.info("hub import queued for #{path}")
            state

          {:error, reason} ->
            warn_once(
              state,
              {:import_task, path},
              "could not start hub import for #{path}: #{inspect(reason)}"
            )
        end
      catch
        :exit, reason ->
          warn_once(
            state,
            {:import_task, path},
            "could not start hub import for #{path}: #{inspect(reason)}"
          )
      end
    end
  end

  defp submit_import(path, name, slug) do
    attrs = %{"work_dir" => path, "name" => name, "slug" => slug}

    case Importer.submit(attrs) do
      {:ok, job} ->
        Logger.info("hub import for #{path}: #{job.total} commit(s)")

      {:error, reason} ->
        Logger.warning(
          "hub import failed for #{path}: #{inspect(reason)}; importing the working tree"
        )

        case do_register_plain(path, name, slug) do
          {:ok, project} ->
            Logger.info("discovered project #{project.slug} at #{path}")

          {:error, :already_registered} ->
            Logger.info("hub project already registered at #{path}")

          {:error, other} ->
            Logger.warning("could not register hub child #{path}: #{inspect(other)}")
        end
    end
  end

  defp register_plain(state, path, name, slug) do
    case do_register_plain(path, name, slug) do
      {:ok, project} ->
        Logger.info("discovered project #{project.slug} at #{path}")
        %{state | warned: MapSet.delete(state.warned, {:register, path})}

      {:error, :already_registered} ->
        state

      {:error, %Ecto.Changeset{} = changeset} ->
        warn_once(
          state,
          {:register, path},
          "could not register #{path}: #{inspect(changeset.errors)}"
        )

      {:error, reason} ->
        warn_once(state, {:register, path}, "could not register #{path}: #{inspect(reason)}")
    end
  end

  defp do_register_plain(path, name, slug) do
    case Projects.register_project(%{"name" => name, "slug" => slug, "work_dir" => path}) do
      {:ok, project} ->
        snapshot_imported(project, path)
        {:ok, project}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The hub saw an existing tree, not a history. Record that boundary once so
  # the project is visibly imported before the watcher sees later edits.
  defp snapshot_imported(project, path) do
    case ProjectRegistry.lookup_queue(project.id) do
      nil ->
        Logger.warning("no commit queue for discovered project #{project.slug} at #{path}")

      queue ->
        try do
          case CommitQueue.commit(queue, "import: existing working tree",
                 flags: [:imported],
                 timeout: 60_000
               ) do
            {:ok, _node} -> :ok
            {:error, reason} -> Logger.warning("could not snapshot #{path}: #{inspect(reason)}")
          end
        catch
          :exit, reason ->
            Logger.warning("could not snapshot #{path}: #{inspect(reason)}")
        end
    end
  end

  defp git_repository?(path) do
    match?({:ok, _repo}, GitStore.detect_repository(path))
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp import_active?(path) do
    Enum.any?(Importer.list(), fn job ->
      job.status in [:queued, :running] and Path.expand(job.source.path) == Path.expand(path)
    end)
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  defp registered?(path), do: Repo.get_by(ProjectLocation, work_dir: path) != nil

  # Do not create duplicate snapshots when a candidate is inside an existing
  # project or contains one. The hub itself counts as a parent.
  defp overlap(path) do
    Enum.find_value(Repo.all(ProjectLocation), fn %{work_dir: other} ->
      other = Path.expand(other)

      if other != path and (inside?(path, other) or inside?(other, path)) do
        other
      end
    end)
  end

  defp inside?(child, parent), do: child == parent or String.starts_with?(child, parent <> "/")

  defp unique_slug(base), do: unique_slug(base, base, 2)

  defp unique_slug(base, candidate, suffix) when suffix <= @max_slug_suffix do
    if Repo.get_by(Project, slug: candidate) do
      unique_slug(base, "#{base}-#{suffix}", suffix + 1)
    else
      candidate
    end
  end

  defp unique_slug(_base, candidate, _suffix), do: candidate

  defp hidden?(name), do: String.starts_with?(name, ".")

  defp direct_child?(root, path) do
    Path.dirname(Path.expand(path)) == Path.expand(root)
  end

  ## Filesystem backend

  defp open_backend(state) do
    if File.dir?(state.root) do
      fs_opts = [dirs: [state.root], backend: state.backend, recursive: false]

      fs_opts =
        case state.interval do
          nil -> fs_opts
          interval -> Keyword.put(fs_opts, :interval, interval)
        end

      case start_backend(fs_opts) do
        {:ok, worker} ->
          FileSystem.subscribe(worker)
          %{state | worker: worker, warned: MapSet.delete(state.warned, :missing)}

        :ignore ->
          state
          |> warn_once(:backend, "no file-system backend for projects root #{state.root}")
          |> schedule_reconnect()

        {:error, reason} ->
          state
          |> warn_once(
            {:backend, reason},
            "projects root watcher for #{state.root} unavailable: #{inspect(reason)}"
          )
          |> schedule_reconnect()
      end
    else
      state
      |> warn_once(
        :missing,
        "projects root #{state.root} is not a directory; retrying every #{@reconnect_ms} ms"
      )
      |> schedule_reconnect()
    end
  end

  defp start_backend(fs_opts) do
    FileSystem.start_link(fs_opts)
  rescue
    exception -> {:error, exception}
  end

  defp schedule_scan(%{scan_timer: timer} = state) when timer != nil do
    Process.cancel_timer(timer)
    %{state | scan_timer: Process.send_after(self(), :scan, state.scan_interval_ms)}
  end

  defp schedule_scan(state) do
    %{state | scan_timer: Process.send_after(self(), :scan, state.scan_interval_ms)}
  end

  defp schedule_reconnect(%{reconnect_timer: nil} = state) do
    %{state | reconnect_timer: Process.send_after(self(), :reconnect, @reconnect_ms)}
  end

  defp schedule_reconnect(state), do: state

  defp warn_once(state, key, message) do
    if MapSet.member?(state.warned, key) do
      state
    else
      Logger.warning(message)
      %{state | warned: MapSet.put(state.warned, key)}
    end
  end
end
