defmodule Cadence.Daemon.TestDocsLLM do
  @moduledoc """
  Injectable fake doc LLM for tests. Never hits a real API (spec §9.3).

  Behavior is controlled via `Application.get_env(:cadence_daemon,
  :test_docs_llm_result, :ok)`:

    - `:ok` — returns a valid docs response creating `README.md`.
    - `{:ok, text}` — returns `text` as the completion.
    - `{:error, reason}` — returns the error.
    - `{:sleep, ms}` — sleeps `ms` then returns the valid response.
    - `{:slow, ms, text}` — sleeps `ms` then returns `text`.
    - `{:block, test_pid, ref, text}` — sends `{:docs_llm_started, ref, pid}` to
      `test_pid` and waits for `{:docs_llm_continue, ref}` before returning
      `text` (deterministic mid-job barriers).
  """

  @valid """
  DOCS_BEGIN
  FILE CREATE README.md
  <<<
  # Project

  ## Overview

  Generated documentation.
  >>>
  DOCS_END
  """

  def complete(_prompt) do
    case Application.get_env(:cadence_daemon, :test_docs_llm_result, :ok) do
      :ok ->
        {:ok, @valid}

      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        {:error, reason}

      {:sleep, ms} ->
        # Deliberate latency injection: the timeout path needs a call still in
        # flight when the docs worker's deadline fires.
        Process.sleep(ms)
        {:ok, @valid}

      {:slow, ms, text} ->
        # Deliberate latency injection: keeps the docs job running so a test can
        # observe intermediate state before the completion returns.
        Process.sleep(ms)
        {:ok, text}

      {:block, test_pid, ref, text} ->
        send(test_pid, {:docs_llm_started, ref, self()})

        receive do
          {:docs_llm_continue, ^ref} -> {:ok, text}
        after
          5_000 -> {:error, :blocked_timeout}
        end
    end
  end

  @doc "The valid DOCS_BEGIN/CREATE response used by tests."
  def valid_response, do: @valid

  def model, do: "test-docs-model"
  def provider, do: "test"
end
