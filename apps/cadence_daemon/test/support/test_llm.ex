defmodule Cadence.Daemon.TestLLM do
  @moduledoc """
  Injectable fake LLM client for tests. Never hits a real API (spec §5.5).

  Behavior is controlled via `Application.get_env(:cadence_daemon, :test_llm_result, :ok)`:

    - `:ok` — returns a fixed valid `SUMMARY/FLAG/DETAIL` response.
    - `{:ok, text}` — returns `text` as the completion.
    - `{:error, reason}` — returns the error.
    - `{:sleep, ms}` — sleeps `ms` then returns the valid response (for timeout tests).
  """

  @valid "SUMMARY: Added feature\nFLAG: in-progress\nDETAIL:\n- first thing\n- second thing\n"

  def complete(_prompt) do
    case Application.get_env(:cadence_daemon, :test_llm_result, :ok) do
      :ok ->
        {:ok, @valid}

      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        {:error, reason}

      {:sleep, ms} ->
        # Deliberate latency injection: timeout tests need a completion that is
        # still running when the worker's deadline fires.
        Process.sleep(ms)
        {:ok, @valid}
    end
  end

  def model, do: "test-model"
end
