defmodule Cadence.Server.FakeDocker do
  @moduledoc """
  Injectable Docker client for tests. No test talks to a real daemon (spec §8).

  Defaults mirror a healthy daemon: the image is present, create/start/stop/
  remove succeed, `wait` exits 0, and `logs` returns one line. `script/1`
  overrides individual callbacks; `on_wait/1` runs a function at the moment the
  runner waits, which is how tests simulate an action writing to `/out`.

  Calls are recorded per callback so tests can assert both the container spec
  and the cleanup order.
  """

  @behaviour Cadence.Server.Actions.Docker

  @table :cadence_test_fake_docker

  @doc "Own the ETS table in the calling test process and clear it."
  def setup do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Override callbacks. Keys match the callback names (`:image?`, `:build_image`,
  `:list_images`, `:remove_image`, `:create`, `:start`, `:wait`, `:logs`,
  `:stop`, `:remove`) plus `:on_wait`, a zero-arity function executed just
  before `wait/1` returns.
  """
  def script(overrides) when is_map(overrides) do
    ensure_table()
    :ets.insert(@table, {:script, overrides})
    :ok
  end

  @doc "Recorded arguments for one callback, oldest first."
  def calls(name) do
    ensure_table()

    case :ets.lookup(@table, {:calls, name}) do
      [{_key, calls}] -> Enum.reverse(calls)
      [] -> []
    end
  end

  @doc "The most recent argument list for `name`, or `nil`."
  def last_call(name), do: name |> calls() |> List.last()

  ## Callbacks

  @impl true
  def image?(image) do
    record(:image?, [image])
    scripted(:image?, {:ok, true})
  end

  @impl true
  def build_image(code_dir, files, tag) do
    record(:build_image, [code_dir, files, tag])
    scripted(:build_image, :ok)
  end

  @impl true
  def list_images do
    record(:list_images, [])
    scripted(:list_images, {:ok, []})
  end

  @impl true
  def remove_image(tag) do
    record(:remove_image, [tag])
    scripted(:remove_image, :ok)
  end

  @impl true
  def create(spec) do
    record(:create, [spec])
    scripted(:create, {:ok, "container-1"})
  end

  @impl true
  def start(id) do
    record(:start, [id])
    scripted(:start, :ok)
  end

  @impl true
  def wait(id) do
    record(:wait, [id])
    run_hook(:on_wait)
    scripted(:wait, {:ok, 0})
  end

  @impl true
  def logs(id, max_bytes) do
    record(:logs, [id, max_bytes])
    scripted(:logs, {:ok, "action output\n"})
  end

  @impl true
  def stop(id) do
    record(:stop, [id])
    scripted(:stop, :ok)
  end

  @impl true
  def remove(id) do
    record(:remove, [id])
    scripted(:remove, :ok)
  end

  ## Internals

  defp record(name, args) do
    ensure_table()

    existing =
      case :ets.lookup(@table, {:calls, name}) do
        [{_key, calls}] -> calls
        [] -> []
      end

    :ets.insert(@table, {{:calls, name}, [args | existing]})
  end

  defp scripted(name, default) do
    case script_value(name) do
      nil -> default
      value -> value
    end
  end

  defp run_hook(name) do
    case script_value(name) do
      fun when is_function(fun, 0) -> fun.()
      _other -> :ok
    end
  end

  defp script_value(name) do
    ensure_table()

    case :ets.lookup(@table, :script) do
      [{:script, overrides}] -> Map.get(overrides, name)
      [] -> nil
    end
  end

  # The table must be owned by the test process; a task that created it first
  # would lose it when it exits. Mirrors TestMeldLLM.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _reference -> @table
    end
  end
end
