defmodule Cadence.Shared.LLMTest do
  use ExUnit.Case, async: false

  alias Cadence.Shared.LLM

  test "reports configured only when an api key is present" do
    put_config(api_key: nil)
    refute LLM.configured?()

    put_config(api_key: "")
    refute LLM.configured?()

    put_config(api_key: "secret")
    assert LLM.configured?()
  end

  test "reads the model and provider from config" do
    put_config(provider: "openai", model: "gpt-test")
    assert LLM.provider() == "openai"
    assert LLM.model() == "gpt-test"

    put_config([])
    assert LLM.provider() == "deepseek"
    assert LLM.model() == nil
  end

  test "complete/1 degrades gracefully without a key" do
    put_config(api_key: nil)
    assert LLM.complete("hello") == {:error, :not_configured}
  end

  defp put_config(config) do
    Application.put_env(:cadence_shared, LLM, config)
    on_exit(fn -> Application.delete_env(:cadence_shared, LLM) end)
  end
end
