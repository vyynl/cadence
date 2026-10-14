defmodule Cadence.Daemon.AgentWorker do
  @moduledoc """
  Supervises and rate-limits LLM calls for the daemon (commit messages today).

  A `Task.Supervisor` that gates every LLM call through
  `Cadence.Daemon.LLMRateLimit` and awaits it with a timeout. The LLM client is
  injectable via `Application.get_env(:cadence_daemon, :llm, Cadence.Shared.LLM)`
  so tests substitute a fake and never hit a real API (AGENTS.md §9).
  """

  alias Cadence.Daemon.LLMRateLimit
  alias Cadence.Shared.LLM.CommitMessage

  @rate_key :llm

  def start_link(opts) do
    Task.Supervisor.start_link(Keyword.put(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Generates a commit message from `diff_text`.

  Returns `{:ok, %{summary, flag, details, model}}` on success, or
  `{:error, reason}` where `reason` is `{:rate_limited, timeout_ms}`,
  `:timeout`, `:not_configured`, `:missing_summary`, or an LLM error.
  """
  @spec generate_commit_message(String.t()) ::
          {:ok,
           %{
             summary: String.t(),
             flag: atom() | nil,
             details: [String.t()],
             model: String.t() | nil
           }}
          | {:error, term()}
  def generate_commit_message(diff_text) when is_binary(diff_text) do
    case LLMRateLimit.hit(@rate_key, rate_scale(), rate_limit()) do
      {:allow, _} -> run(diff_text)
      {:deny, timeout} -> {:error, {:rate_limited, timeout}}
    end
  end

  defp run(diff_text) do
    llm = llm_module()
    prompt = CommitMessage.build_prompt(diff_text)

    task = Task.Supervisor.async_nolink(__MODULE__, fn -> llm.complete(prompt) end)

    case Task.yield(task, timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, text}} ->
        case CommitMessage.parse(text) do
          {:ok, %{summary: summary, flag: flag, details: details}} ->
            {:ok, %{summary: summary, flag: flag, details: details, model: llm.model()}}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, {:error, reason}} ->
        {:error, reason}

      nil ->
        {:error, :timeout}

      {:exit, reason} ->
        {:error, {:exit, reason}}
    end
  end

  defp rate_limit, do: Application.get_env(:cadence_daemon, :llm_rate_limit, 10)
  defp rate_scale, do: Application.get_env(:cadence_daemon, :llm_rate_scale, 60_000)
  defp timeout_ms, do: Application.get_env(:cadence_daemon, :llm_timeout_ms, 5_000)
  defp llm_module, do: Application.get_env(:cadence_daemon, :llm, Cadence.Shared.LLM)
end
