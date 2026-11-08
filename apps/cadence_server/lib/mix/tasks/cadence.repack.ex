defmodule Mix.Tasks.Cadence.Repack do
  @shortdoc "Repack a project's loose Git objects (or every project)"

  @moduledoc """
  Packs loose Git objects for one project or for every project (spec §13
  Phase 7b).

      mix cadence.repack [--project <id|slug>] [--all]

  Manual runs are unconditional: the storage threshold is ignored, but
  `CAD_REPACK_ENABLED` and the per-project advisory lock still apply. With no
  `--project`, every project is repacked (`--all` is an explicit synonym). A
  run writes packs and sweeps loose copies that a **previous** verified run
  covered, so an object needs two runs to disappear: the first packs it, the
  second verifies and unlinks it. Pack + loose coexist until then (at most one
  backstop interval, so budget transient 2× object storage). The manual task is
  operator-controlled: `CAD_REPACK_TIMEOUT_MS` bounds only the background
  worker, so a `mix` run is not interrupted (`Ctrl-C` it if it hangs).

  This task is `mix`-only. It never binds the HTTP port, so it is safe inside an
  already-running container (`docker compose exec server mix cadence.repack`).
  """

  use Mix.Task

  import Ecto.Query

  alias Cadence.Server.{Portfolio, Repo, Storage}
  alias Cadence.Shared.Project

  @impl true
  def run(argv) do
    Mix.Task.run("app.config")

    {opts, args, invalid} =
      OptionParser.parse(argv, strict: [project: :string, all: :boolean])

    if invalid != [] or args != [] do
      Mix.raise("usage: mix cadence.repack [--project <id|slug>] [--all]")
    end

    if opts[:project] && opts[:all] do
      Mix.raise("choose either --project or --all, not both")
    end

    start_app()

    unless Storage.enabled?() do
      Mix.raise("repacking is disabled (CAD_REPACK_ENABLED=false)")
    end

    results = Enum.map(resolve_projects(opts[:project]), &repack/1)

    if Enum.any?(results, &match?({:error, _label, _reason}, &1)) do
      Mix.raise("one or more projects failed to repack")
    end
  end

  defp start_app do
    # Repo and the storage children are all a run needs; never bind the port.
    # A maintenance task must not drain the action run queue as a side effect
    # (the Dispatcher's boot pass is disabled for this process only).
    Application.put_env(:cadence_server, :actions_dispatch_on_boot, false)
    endpoint_config = Application.get_env(:cadence_server, Cadence.ServerWeb.Endpoint, [])

    Application.put_env(
      :cadence_server,
      Cadence.ServerWeb.Endpoint,
      Keyword.put(endpoint_config, :server, false)
    )

    case Application.ensure_all_started(:cadence_server) do
      {:ok, _apps} -> :ok
      {:error, reason} -> Mix.raise("could not start cadence_server: #{inspect(reason)}")
    end
  end

  defp resolve_projects(nil) do
    Repo.all(from p in Project, order_by: [asc: p.slug], select: {p.id, p.slug})
  end

  defp resolve_projects(value) when is_binary(value) do
    [resolve_project(value)]
  end

  defp resolve_project(value) do
    found =
      case Ecto.UUID.cast(value) do
        {:ok, id} ->
          case Repo.get(Project, id) do
            nil -> :not_found
            project -> {:ok, project}
          end

        :error ->
          Portfolio.get_project_by_slug(value)
      end

    case found do
      {:ok, project} -> {project.id, project.slug}
      :not_found -> Mix.raise("unknown project: #{value}")
      {:error, :not_found} -> Mix.raise("unknown project: #{value}")
    end
  end

  defp repack({project_id, slug}) do
    shell = Mix.shell()
    before = Storage.stats(project_id)

    shell.info("#{slug} (#{project_id})")

    shell.info(
      "  before: #{before.loose_objects} loose objects (#{bytes(before.loose_bytes)}), #{describe_packs(before)}"
    )

    case Storage.run(project_id) do
      {:ok, summary} ->
        shell.info(
          "  after:  #{summary.swept_loose} loose copies swept " <>
            "(#{summary.unlink_failed} unlink failure(s)), " <>
            "#{length(summary.packs)} new pack(s) with #{summary.packed_objects} object(s) " <>
            "(#{bytes(summary.packed_bytes)}), " <>
            "#{summary.swept_tmp + summary.swept_orphans} temp/orphan file(s) removed " <>
            "(#{summary.cleanup_failed} failure(s)), " <>
            "#{summary.skipped} skipped, #{summary.duration_ms} ms"
        )

        :ok

      {:error, :busy} ->
        shell.info("  skipped: another run holds this project's lock")
        :ok

      {:error, reason} ->
        shell.error("  failed: #{inspect(reason)}")
        {:error, slug, reason}
    end
  end

  defp describe_packs(%{pack_count: 0, packed_objects: 0}), do: "no packs"

  defp describe_packs(%{pack_count: count, packed_objects: objects}),
    do: "#{count} pack(s), #{objects} object(s)"

  defp bytes(size) when size >= 1_048_576, do: "#{Float.round(size / 1_048_576, 1)} MiB"
  defp bytes(size) when size >= 1_024, do: "#{Float.round(size / 1_024, 1)} KiB"
  defp bytes(size), do: "#{size} B"
end
