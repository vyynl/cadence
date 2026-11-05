defmodule Cadence.Server.MeldWorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cadence.Server.{MeldWorker, TestMeldLLM}

  @keys [
    :meld_timeout_ms,
    :meld_rate_limit,
    :meld_rate_scale,
    :meld_context_bytes,
    :meld_retry_attempts,
    :meld_retry_backoff_ms
  ]

  @parents [
    %{id: "p1", message: "first session", flags: [:"in-progress"], files: %{}},
    %{id: "p2", message: "second session", flags: [:broken], files: %{}}
  ]

  @conflicts %{
    "src/conflict.txt" => [
      %{id: "p1", ref: "a", content: "one"},
      %{id: "p2", ref: "b", content: "two"}
    ]
  }

  setup do
    previous = Map.new(@keys, &{&1, Application.get_env(:cadence_server, &1)})
    previous_llm = Application.get_env(:cadence_server, :meld_llm)

    Application.put_env(:cadence_server, :meld_llm, TestMeldLLM)
    TestMeldLLM.setup()

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:cadence_server, key)
        {key, value} -> Application.put_env(:cadence_server, key, value)
      end)

      if previous_llm do
        Application.put_env(:cadence_server, :meld_llm, previous_llm)
      else
        Application.delete_env(:cadence_server, :meld_llm)
      end

      TestMeldLLM.reset()
    end)

    :ok
  end

  test "returns the completion and provenance from the injectable client" do
    TestMeldLLM.script([{:ok, "MELD_BEGIN\nMELD_END\n"}])

    assert {:ok, result} = MeldWorker.resolve(@parents, @conflicts)
    assert result.text == "MELD_BEGIN\nMELD_END\n"
    assert result.model == "test-meld-model"
    assert result.provider == "test-provider"
    assert result.prompt_version == "meld-v1"
    assert TestMeldLLM.calls() == 1

    prompt = TestMeldLLM.last_prompt()
    assert prompt =~ "Message: first session"
    assert prompt =~ "Flags: in-progress"
    assert prompt =~ "src/conflict.txt"
  end

  test "configuration errors are returned without a retry" do
    Application.put_env(:cadence_server, :meld_retry_attempts, 3)
    TestMeldLLM.script([{:error, :not_configured}])

    assert MeldWorker.resolve(@parents, @conflicts) == {:error, :not_configured}
    assert TestMeldLLM.calls() == 1
  end

  test "a call exceeding the deadline returns :timeout" do
    Application.put_env(:cadence_server, :meld_timeout_ms, 10)
    Application.put_env(:cadence_server, :meld_retry_attempts, 1)
    TestMeldLLM.script([{:sleep, 200}])

    assert MeldWorker.resolve(@parents, @conflicts) == {:error, :timeout}
  end

  test "a denied rate limit never calls the client" do
    Application.put_env(:cadence_server, :meld_rate_limit, 0)

    assert {:error, {:rate_limited, _retry_after}} = MeldWorker.resolve(@parents, @conflicts)
    assert TestMeldLLM.calls() == 0
  end

  test "a context budget that cannot fit every conflict fails before the client" do
    Application.put_env(:cadence_server, :meld_context_bytes, 13)
    Application.put_env(:cadence_server, :meld_retry_attempts, 3)

    conflicts = %{
      "a.txt" => [%{id: "p1", ref: "a", content: "one"}],
      "b.txt" => [%{id: "p1", ref: "b", content: "two"}]
    }

    assert MeldWorker.resolve(@parents, conflicts) == {:error, :context_too_large}
    assert TestMeldLLM.calls() == 0
  end

  test "transient provider errors are retried once" do
    Application.put_env(:cadence_server, :meld_retry_attempts, 1)
    Application.put_env(:cadence_server, :meld_retry_backoff_ms, 0)
    TestMeldLLM.script([{:error, :boom}, {:ok, "MELD_BEGIN\nMELD_END\n"}])

    assert {:ok, %{text: "MELD_BEGIN\nMELD_END\n"}} = MeldWorker.resolve(@parents, @conflicts)
    assert TestMeldLLM.calls() == 2
  end

  test "retries stop after the configured attempts" do
    Application.put_env(:cadence_server, :meld_retry_attempts, 1)
    Application.put_env(:cadence_server, :meld_retry_backoff_ms, 0)
    TestMeldLLM.script([{:error, :boom}, {:error, :boom}])

    assert MeldWorker.resolve(@parents, @conflicts) == {:error, {:llm, :boom}}
    assert TestMeldLLM.calls() == 2
  end

  @tag :capture_log
  test "a crashing client is reported as an exit" do
    TestMeldLLM.script([:exit])

    assert MeldWorker.resolve(@parents, @conflicts) == {:error, {:exit, :scripted_exit}}
  end

  @tag :capture_log
  test "never logs the prompt or completion text" do
    TestMeldLLM.script([{:ok, "MELD_BEGIN\nMELD_END\nsecret-completion"}])

    log =
      capture_log(fn ->
        assert {:ok, _result} = MeldWorker.resolve(@parents, @conflicts)
      end)

    refute log =~ "first session"
    refute log =~ "src/conflict.txt"
    refute log =~ "secret-completion"
  end
end
