defmodule Cadence.Daemon.DocAgentWorker do
  @moduledoc """
  Runs one documentation-generation LLM call (spec §9.3, §9.6).

  A `Task.Supervisor` gates the call through `Cadence.Daemon.LLMRateLimit`
  (key `:docs`) and bounds it with `CAD_DOCS_TIMEOUT_MS`. The prompt is built
  from the parsed schema, the current docs, and the code diff, then the
  response is parsed by `Cadence.Shared.LLM.Docs` against the schema's allowed
  paths.

  The client is injectable via
  `Application.get_env(:cadence_daemon, :docs_llm, Cadence.Shared.LLM)` so tests
  never reach a real API (AGENTS.md §9).
  """

  alias Cadence.Daemon.{Env, LLMRateLimit}
  alias Cadence.Shared.Docs.Schema
  alias Cadence.Shared.LLM.Docs

  @rate_key :docs

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

  @doc "Whether the configured doc LLM client can make calls."
  @spec configured?() :: boolean()
  def configured? do
    llm = llm_module()

    if Code.ensure_loaded?(llm) and function_exported?(llm, :configured?, 0) do
      llm.configured?()
    else
      true
    end
  end

  @doc "The configured model name, or `nil` when the client does not expose one."
  @spec model() :: String.t() | nil
  def model, do: call_optional(:model)

  @doc "The configured provider name, or `nil` when the client does not expose one."
  @spec provider() :: String.t() | nil
  def provider, do: call_optional(:provider)

  @doc "The prompt template version recorded with every doc result."
  @spec prompt_version() :: String.t()
  def prompt_version, do: Docs.prompt_version()

  @doc """
  Generates documentation operations for one node.

  Returns `{:ok, ops}` or `{:error, reason}` where `reason` is
  `:not_configured`, `{:rate_limited, retry_ms}`, `:timeout`,
  `{:exit, reason}`, `:context_too_large`, an LLM error, or a
  `Cadence.Shared.LLM.Docs.parse/3` error atom.

  Options:

    * `:read_only_paths` — extra doc paths the model must not write
    * `:timeout_ms` — overrides `CAD_DOCS_TIMEOUT_MS`
  """
  @spec generate(Schema.t(), %{String.t() => binary()}, binary(), keyword()) ::
          {:ok, [{:create | :modify, String.t(), binary()}]} | {:error, term()}
  def generate(%Schema{} = schema, docs, diff, opts \\ [])
      when is_map(docs) and is_binary(diff) do
    cond do
      not configured?() ->
        {:error, :not_configured}

      true ->
        case LLMRateLimit.hit(@rate_key, Env.docs_rate_scale(), Env.docs_rate_limit()) do
          {:allow, _count} -> run(schema, docs, diff, opts)
          {:deny, retry_ms} -> {:error, {:rate_limited, retry_ms}}
        end
    end
  end

  defp run(schema, docs, diff, opts) do
    llm = llm_module()
    timeout_ms = Keyword.get(opts, :timeout_ms, Env.docs_timeout_ms())
    read_only = Keyword.get(opts, :read_only_paths, [])

    prompt_opts = [
      max_context_bytes: Env.docs_context_bytes(),
      max_diff_bytes: Env.docs_diff_max_bytes()
    ]

    task =
      Task.Supervisor.async_nolink(__MODULE__, fn ->
        with {:ok, prompt, meta} <- Docs.build_prompt(schema, docs, diff, prompt_opts) do
          case llm.complete(prompt) do
            {:ok, text} ->
              Docs.parse(text, schema,
                max_ops: Env.docs_max_ops(),
                max_file_bytes: Env.docs_max_file_bytes(),
                read_only_paths: meta.read_only_paths ++ read_only
              )

            {:error, reason} ->
              {:error, reason}
          end
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  end

  defp call_optional(fun) do
    llm = llm_module()

    if Code.ensure_loaded?(llm) and function_exported?(llm, fun, 0) do
      apply(llm, fun, [])
    end
  end

  defp llm_module do
    Application.get_env(:cadence_daemon, :docs_llm, Cadence.Shared.LLM)
  end
end
