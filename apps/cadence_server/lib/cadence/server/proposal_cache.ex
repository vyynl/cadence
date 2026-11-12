defmodule Cadence.Server.ProposalCache do
  @moduledoc """
  Bounded FIFO cache of rendered public proposal-result payloads (spec §7.6).

  Rendering a proposal result walks the meld commit and its first parent through
  the capped blob reader and scans the visible result for secrets. Those walks
  are pure functions of the two commits and the configured caps, so the payload
  can be reused across requests — and across proposals that share that content.

  The key is therefore content-derived:
  `{project_id, result_commit_sha, first_parent_sha, max_files,
  scan_max_files, scan_max_bytes}`. The value is the already-filtered payload
  (`quarantined?`, `truncated?`, `hidden_count`, `summary`, `files`) — paths and
  statuses only, never file content, so the §7.6 filtering contract is
  unchanged by caching. Errors and promotions (`:none`) are never stored.

  There is deliberately no invalidation hook in `Cadence.Server.Proposals`.
  Approving or rejecting changes only `status` and `decided_at`, which the page
  renders from the proposal row; a cached payload is a pure function of the
  immutable commits and the caps in its key. Coupling the context to this cache
  would add a write dependency with no correctness gain, so decisions leave
  entries untouched.

  Isolation (`ProposalView.isolated?/1`) is a mutable, incident-derived answer
  and is never cached; callers check it before asking for a result.
  `Proposals.result_integrity/3` and `ProposalView.verify_resolution/1` always
  re-walk and never read this table.

  The bound is `Application.get_env(:cadence_server, :proposal_cache_entries,
  256)`; a non-positive value disables caching (every read misses, every write
  is a no-op). The limit is read per operation, so runtime config changes and
  tests are honored without a restart. The bound is enforced on writes: lowering
  it takes effect on the next put, never on a read.

  The ETS table is owned by this GenServer and created `:protected`, so reads
  are lock-free from any process while only the owner writes; the FIFO bound
  and `:ets.info(:size)` accounting rely on that single-writer invariant. When
  the process is not running (for example a bare `mix run --no-start`) reads
  return `:miss` and writes are ignored, so callers never need to guard.
  """

  use GenServer

  @table :cadence_proposal_cache
  @default_entries 256

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{order: :queue.new()}}
  end

  @doc """
  Configured entry bound. A non-positive value disables the cache entirely.
  """
  @spec entry_limit() :: integer()
  def entry_limit do
    case Application.get_env(:cadence_server, :proposal_cache_entries, @default_entries) do
      value when is_integer(value) -> value
      _other -> @default_entries
    end
  end

  @doc "Whether caching is enabled by configuration."
  @spec enabled?() :: boolean()
  def enabled?, do: entry_limit() > 0

  @doc """
  Look up a cached payload.

  Returns `{:ok, payload}` or `:miss` (including when caching is disabled or the
  cache process is not running).
  """
  @spec get(term()) :: {:ok, map()} | :miss
  def get(key) do
    if enabled?() and table?() do
      case :ets.lookup(@table, key) do
        [{^key, payload}] -> {:ok, payload}
        _other -> :miss
      end
    else
      :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Store a payload, evicting the oldest insertion when the bound is reached.

  A no-op when caching is disabled or the cache process is not running.
  """
  @spec put(term(), map()) :: :ok
  def put(key, payload) do
    if enabled?() and table?() and is_pid(Process.whereis(__MODULE__)) do
      GenServer.call(__MODULE__, {:put, key, payload})
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @doc "Drop every cached payload."
  @spec clear() :: :ok
  def clear do
    cond do
      not table?() ->
        :ok

      is_pid(Process.whereis(__MODULE__)) ->
        GenServer.call(__MODULE__, :clear)

      true ->
        delete_all()
    end
  catch
    :exit, _reason -> :ok
  end

  @doc "Number of cached payloads (0 when disabled or the table is absent)."
  @spec size() :: non_neg_integer()
  def size do
    if enabled?() and table?() do
      case :ets.info(@table, :size) do
        count when is_integer(count) -> count
        _other -> 0
      end
    else
      0
    end
  rescue
    ArgumentError -> 0
  end

  @impl true
  def handle_call({:put, key, payload}, _from, state) do
    state = if table?(), do: put_entry(state, key, payload), else: state

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    if table?(), do: delete_all()

    {:reply, :ok, %{state | order: :queue.new()}}
  end

  defp put_entry(state, key, payload) do
    limit = entry_limit()

    cond do
      limit <= 0 ->
        state

      :ets.member(@table, key) ->
        :ets.insert(@table, {key, payload})
        state

      true ->
        state = make_room(state, limit)
        :ets.insert(@table, {key, payload})
        %{state | order: :queue.in(key, state.order)}
    end
  end

  # Evicts in insertion order until one slot is free. The queue is in-memory
  # GenServer state, so a non-empty table with an empty queue has no order to
  # evict by; clearing it is the only way to keep the bound correct.
  defp make_room(state, limit) do
    if :ets.info(@table, :size) >= limit do
      case :queue.out(state.order) do
        {{:value, oldest}, rest} ->
          :ets.delete(@table, oldest)
          make_room(%{state | order: rest}, limit)

        {:empty, _queue} ->
          delete_all()
          %{state | order: :queue.new()}
      end
    else
      state
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :protected,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp delete_all do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp table?(), do: :ets.whereis(@table) != :undefined
end
