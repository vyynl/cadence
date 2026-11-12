defmodule Cadence.Server.TestMeldLLM do
  @moduledoc """
  Injectable fake meld LLM client. Never hits a real API (spec §6.5).

  Behavior comes from a per-test ETS script first, then
  `Application.get_env(:cadence_server, :meld_llm_result)`:

    - `{:ok, text}` — return `text` as the completion.
    - `{:error, reason}` — return the error.
    - `{:sleep, ms}` — sleep, then return a minimal valid response.
    - `:exit` — crash the calling task (for `{:exit, reason}` coverage).

  `script/1` enqueues a list of those tuples, consumed in order (used for retry
  tests). `calls/0` and `last_prompt/0` let tests assert what the worker did
  without logging prompt or completion text.
  """

  @table :cadence_test_meld_llm
  @empty_response "MELD_BEGIN\nMELD_END\n"

  @doc """
  Create/own the ETS table in the calling test process and clear it.

  Call from `setup/0`. The table must be owned by the test process: if the
  worker `Task` creates it first, the table dies with the task and `calls/0` /
  `last_prompt/0` silently report 0 / nil.
  """
  def setup do
    ensure_table()
    :ets.delete_all_objects(@table)
    Application.delete_env(:cadence_server, :meld_llm_result)
    :ok
  end

  @doc "Alias for `setup/0`; safe to call from `on_exit`."
  def reset, do: setup()

  @doc "Queue scripted responses consumed one per `complete/1` call."
  def script(responses) when is_list(responses) do
    ensure_table()
    :ets.insert(@table, {:script, responses})
    :ok
  end

  @doc "Number of `complete/1` calls made since `reset/0`."
  def calls do
    ensure_table()

    case :ets.lookup(@table, :calls) do
      [{:calls, count}] -> count
      [] -> 0
    end
  end

  @doc "The last prompt passed to `complete/1`, or `nil`."
  def last_prompt do
    ensure_table()

    case :ets.lookup(@table, :last_prompt) do
      [{:last_prompt, prompt}] -> prompt
      [] -> nil
    end
  end

  def complete(prompt) do
    ensure_table()
    :ets.update_counter(@table, :calls, 1, {:calls, 0})
    :ets.insert(@table, {:last_prompt, prompt})

    case next_scripted() do
      :none ->
        respond(Application.get_env(:cadence_server, :meld_llm_result, {:ok, @empty_response}))

      response ->
        respond(response)
    end
  end

  def model, do: "test-meld-model"
  def provider, do: "test-provider"

  defp next_scripted do
    case :ets.lookup(@table, :script) do
      [{:script, [next | rest]}] ->
        :ets.insert(@table, {:script, rest})
        next

      _ ->
        :none
    end
  end

  defp respond({:ok, text}), do: {:ok, text}
  defp respond({:error, reason}), do: {:error, reason}

  defp respond({:sleep, ms}) do
    # Deliberate latency injection: keeps a meld call in flight so the worker's
    # timeout and retry paths can be observed.
    Process.sleep(ms)
    {:ok, @empty_response}
  end

  defp respond(:exit), do: exit(:scripted_exit)

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public])
    end
  rescue
    ArgumentError -> :ok
  end
end
