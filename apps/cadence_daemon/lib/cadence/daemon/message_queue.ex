defmodule Cadence.Daemon.MessageQueue do
  @moduledoc """
  Retries commit-message generation that failed during a commit (spec §5.4, §5.5).

  When an LLM call fails at commit time, the node is persisted with a
  placeholder message and `session_metadata["message_pending"] = true`, then
  enqueued here. The queue recomputes the diff from the Git object store,
  retries the LLM with backoff, and on success updates `node.message` (DB only —
  the Git commit object keeps its placeholder so the SHA stays stable).

  Pending nodes are re-enqueued on boot via `rehydrate/0`.
  """

  use GenServer

  alias Cadence.Daemon.{AgentWorker, ProjectLocation, Repo}
  alias Cadence.Shared.{GitStore, Node}
  alias Cadence.Shared.LLM.CommitMessage

  defstruct entries: %{}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueues a node for message retry. Idempotent for a given node."
  def enqueue(project_id, node_id) do
    GenServer.cast(__MODULE__, {:enqueue, project_id, node_id})
  end

  @doc """
  Re-enqueues all nodes still marked `message_pending` (boot-time recovery).
  Best-effort: no-op if the tables are missing.
  """
  def rehydrate do
    Node
    |> Repo.all()
    |> Enum.each(fn node ->
      if node.session_metadata["message_pending"] == true do
        enqueue(node.project_id, node.id)
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_cast({:enqueue, project_id, node_id}, state) do
    if Map.has_key?(state.entries, node_id) do
      {:noreply, state}
    else
      entry = %{project_id: project_id, attempts: 0}
      schedule_retry(node_id, 0)
      {:noreply, %{state | entries: Map.put(state.entries, node_id, entry)}}
    end
  end

  @impl true
  def handle_info({:retry, node_id}, state) do
    case Map.get(state.entries, node_id) do
      nil ->
        {:noreply, state}

      entry ->
        case retry_node(node_id, entry) do
          :ok ->
            {:noreply, %{state | entries: Map.delete(state.entries, node_id)}}

          {:retry, entry} ->
            schedule_retry(node_id, entry.attempts)
            {:noreply, %{state | entries: Map.put(state.entries, node_id, entry)}}

          :drop ->
            clear_pending(node_id)
            {:noreply, %{state | entries: Map.delete(state.entries, node_id)}}
        end
    end
  end

  defp retry_node(node_id, entry) do
    case Repo.get(Node, node_id) do
      nil ->
        maybe_reschedule(entry)

      node ->
        with {:ok, diff_text} <- build_diff_text(node),
             {:ok, result} <- AgentWorker.generate_commit_message(diff_text),
             {:ok, _} <- apply_message(node, result) do
          :ok
        else
          _ -> maybe_reschedule(entry)
        end
    end
  end

  defp maybe_reschedule(%{attempts: attempts} = entry) do
    max = Application.get_env(:cadence_daemon, :llm_retry_attempts, 3)

    if attempts + 1 >= max do
      :drop
    else
      {:retry, %{entry | attempts: attempts + 1}}
    end
  end

  defp schedule_retry(node_id, attempt) do
    Process.send_after(self(), {:retry, node_id}, backoff_ms(attempt))
  end

  # The first attempt (attempt 0, on enqueue) fires immediately; later attempts
  # back off linearly.
  defp backoff_ms(0), do: Application.get_env(:cadence_daemon, :llm_retry_initial_ms, 0)

  defp backoff_ms(attempt) do
    base = Application.get_env(:cadence_daemon, :llm_retry_backoff_ms, 5_000)
    base * attempt
  end

  defp build_diff_text(node) do
    case Repo.get_by(ProjectLocation, project_id: node.project_id) do
      nil -> {:error, :no_location}
      location -> build_diff_text(node, location)
    end
  end

  defp build_diff_text(node, location) do
    git = GitStore.open(location.git_dir, bare: true)

    case GitStore.read_commit(git, node.git_commit_sha) do
      nil ->
        {:error, :no_commit}

      %{tree: new_tree} ->
        old_tree = parent_tree(git, node.parents)
        changes = GitStore.diff_trees(git, old_tree, new_tree)
        {:ok, CommitMessage.diff_to_text(changes, diff_max_bytes())}
    end
  end

  defp parent_tree(_git, []), do: nil

  defp parent_tree(git, [parent_id | _]) do
    case Repo.get(Node, parent_id) do
      nil ->
        nil

      parent ->
        case GitStore.read_commit(git, parent.git_commit_sha) do
          nil -> nil
          commit -> commit.tree
        end
    end
  end

  defp apply_message(node, %{summary: summary, details: details, flag: flag, model: model}) do
    message = CommitMessage.render(%{summary: summary, details: details})

    metadata =
      node.session_metadata
      |> Map.put("model", model)
      |> Map.delete("message_pending")

    node
    |> Node.changeset(%{
      message: message,
      flags: [CommitMessage.clamp_flag(flag)],
      session_metadata: metadata
    })
    |> Repo.update()
  end

  defp clear_pending(node_id) do
    case Repo.get(Node, node_id) do
      nil ->
        :ok

      node ->
        metadata = Map.delete(node.session_metadata, "message_pending")
        Repo.update(Node.changeset(node, %{session_metadata: metadata}))
    end
  end

  defp diff_max_bytes do
    Application.get_env(:cadence_daemon, :llm_diff_max_bytes, 32_768)
  end
end
