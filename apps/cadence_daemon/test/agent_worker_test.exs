defmodule Cadence.Daemon.AgentWorkerTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.AgentWorker

  setup do
    Application.put_env(:cadence_daemon, :llm, Cadence.Daemon.TestLLM)
    Application.put_env(:cadence_daemon, :test_llm_result, :ok)

    on_exit(fn ->
      Application.delete_env(:cadence_daemon, :llm)
      Application.delete_env(:cadence_daemon, :test_llm_result)
      Application.delete_env(:cadence_daemon, :llm_rate_limit)
      Application.delete_env(:cadence_daemon, :llm_timeout_ms)
    end)

    :ok
  end

  test "returns a parsed message on success" do
    Application.put_env(
      :cadence_daemon,
      :test_llm_result,
      {:ok, "SUMMARY: Add thing\nFLAG: broken\nDETAIL:\n- detail\n"}
    )

    assert {:ok, %{summary: "Add thing", flag: :broken, details: ["detail"], model: "test-model"}} =
             AgentWorker.generate_commit_message("some diff")
  end

  test "returns an error when the response is malformed" do
    Application.put_env(:cadence_daemon, :test_llm_result, {:ok, "garbage"})

    assert {:error, :missing_summary} = AgentWorker.generate_commit_message("diff")
  end

  test "returns rate_limited when the limiter denies" do
    Application.put_env(:cadence_daemon, :llm_rate_limit, 0)

    assert {:error, {:rate_limited, _}} = AgentWorker.generate_commit_message("diff")
  end

  test "returns timeout when the LLM exceeds the deadline" do
    Application.put_env(:cadence_daemon, :test_llm_result, {:sleep, 200})
    Application.put_env(:cadence_daemon, :llm_timeout_ms, 10)

    assert {:error, :timeout} = AgentWorker.generate_commit_message("diff")
  end
end
