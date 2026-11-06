defmodule Cadence.Server.MeldWorker do
  @moduledoc """
  Supervises, times out, and rate-limits the server-side meld LLM call
  (spec §6.5, §9).

  A `Task.Supervisor` that gates every meld resolution through
  `Cadence.Server.LLMRateLimit`, builds the prompt from the shared template,
  and awaits the injectable client with a hard timeout. Transient provider
  errors are retried a bounded number of times; rate-limit denials, timeouts,
  and configuration errors are returned immediately.

  The client is injectable via `Application.get_env(:cadence_server, :meld_llm,
  Cadence.Shared.LLM)` so tests never hit a real API. Nothing here logs the
  prompt or the completion text.
  """

  alias Cadence.Server.LLMRateLimit
  alias Cadence.Shared.LLM.Meld, as: MeldPrompt

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
  Ask the model to resolve `conflicts`.

  Options: `:scope` namespaces the rate-limit bucket (the meld pipeline passes
  the project id, so one project cannot exhaust another project's budget).

  Returns `{:ok, %{text, model, provider, prompt_version}}` or
  `{:error, reason}` where `reason` is `:not_configured`, `:timeout`,
  `:context_too_large`, `{:rate_limited, ms}`, `{:llm, term}`, or
  `{:exit, term}`.

  `:timeout` is per attempt; provider errors are retried
  `CAD_MELD_RETRY_ATTEMPTS` times, so a synchronous caller must budget
  `(attempts + 1) × timeout + backoff` (spec §10.6).
  """
  @spec resolve([map()], map(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve(parents, conflicts, opts \\ []) when is_list(parents) and is_map(conflicts) do
    rate_key = {:meld, Keyword.get(opts, :scope, :global)}

    case LLMRateLimit.hit(rate_key, rate_scale(), rate_limit()) do
      {:allow, _count} -> run(parents, conflicts)
      {:deny, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end

  defp run(parents, conflicts) do
    llm = llm_module()

    with {:ok, prompt} <-
           MeldPrompt.build_prompt(parents, conflicts, max_context_bytes: context_bytes()) do
      do_run(llm, prompt, retry_attempts())
    end
  end

  defp do_run(llm, prompt, retries_left) do
    case call(llm, prompt) do
      {:ok, text} ->
        {:ok,
         %{
           text: text,
           model: model(llm),
           provider: provider(llm),
           prompt_version: MeldPrompt.prompt_version()
         }}

      {:error, {:llm, _reason}} when retries_left > 0 ->
        Process.sleep(retry_backoff_ms())
        do_run(llm, prompt, retries_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(llm, prompt) do
    task = Task.Supervisor.async_nolink(__MODULE__, fn -> llm.complete(prompt) end)

    case Task.yield(task, timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, text}} when is_binary(text) ->
        {:ok, text}

      {:ok, {:error, :not_configured}} ->
        {:error, :not_configured}

      {:ok, {:error, reason}} ->
        {:error, {:llm, reason}}

      {:ok, other} ->
        {:error, {:llm, {:unexpected_response, other}}}

      nil ->
        {:error, :timeout}

      {:exit, reason} ->
        {:error, {:exit, reason}}
    end
  end

  defp model(llm) do
    if Code.ensure_loaded?(llm) and function_exported?(llm, :model, 0) do
      llm.model()
    else
      Cadence.Shared.LLM.model()
    end
  end

  defp provider(llm) do
    if Code.ensure_loaded?(llm) and function_exported?(llm, :provider, 0) do
      llm.provider()
    else
      Cadence.Shared.LLM.provider()
    end
  end

  defp timeout_ms, do: config_int(:meld_timeout_ms, 60_000)
  defp rate_limit, do: config_int(:meld_rate_limit, 5)
  defp rate_scale, do: config_int(:meld_rate_scale, 60_000)
  defp context_bytes, do: config_int(:meld_context_bytes, 65_536)
  defp retry_attempts, do: config_int(:meld_retry_attempts, 1)
  defp retry_backoff_ms, do: config_int(:meld_retry_backoff_ms, 500)

  defp llm_module, do: Application.get_env(:cadence_server, :meld_llm, Cadence.Shared.LLM)

  defp config_int(key, default) do
    case Application.get_env(:cadence_server, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end
end
