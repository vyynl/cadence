defmodule Cadence.Daemon.ImportClient do
  @moduledoc """
  Socket client helpers for `mix cad.import` and
  `Cadence.Daemon.Release.import/2`.

  The daemon owns validation and job execution; these helpers only build the
  request body, submit it, and poll `GET /import/:id` until the job reaches a
  terminal state.
  """

  alias Cadence.Daemon.{Client, Env}

  @poll_ms 250

  @doc """
  Submits an import and returns the queued job map.

  Returns `{:ok, job}` or `{:error, {status, message}}`.
  """
  @spec start(map(), Path.t()) :: {:ok, map()} | {:error, {integer(), String.t()}}
  def start(attrs, socket \\ Cadence.Daemon.API.socket_path()) do
    case Client.request("POST", "/import", attrs, socket) do
      %{status: 202, body: %{"job" => job}} ->
        {:ok, job}

      %{status: status, body: body} ->
        {:error, {status, error_message(body)}}
    end
  end

  @doc "Fetches one job's state."
  @spec status(String.t(), Path.t()) :: {:ok, map()} | {:error, {integer(), String.t()}}
  def status(job_id, socket \\ Cadence.Daemon.API.socket_path()) do
    case Client.request("GET", "/import/#{job_id}", nil, socket) do
      %{status: 200, body: %{"job" => job}} ->
        {:ok, job}

      %{status: status, body: body} ->
        {:error, {status, error_message(body)}}
    end
  end

  @doc """
  Polls a job until it is `completed` or `failed`.

  The bound starts when the job actually starts running (queue time is not
  charged to it, because jobs run one at a time). It defaults to the daemon's
  import time bound plus a minute, so a stuck job is reported instead of
  hanging the CLI forever.
  """
  @spec wait(String.t(), Path.t(), pos_integer() | nil) ::
          {:ok, map()} | {:error, :timeout | {integer(), String.t()}}
  def wait(job_id, socket \\ Cadence.Daemon.API.socket_path(), timeout_ms \\ nil) do
    timeout =
      timeout_ms ||
        case Env.import_max_seconds() do
          0 -> :infinity
          seconds -> seconds * 1_000 + 60_000
        end

    do_wait(job_id, socket, :queued, timeout)
  end

  @doc """
  Builds the `POST /import` body from a path and keyword options.

  Accepts `:refs` (list), `:all_refs`, `:allow_shallow`, `:limit`,
  `:project_id` (also `:project`), `:name`, and `:slug`. Nil/empty values are
  omitted so the daemon's defaults apply.
  """
  @spec attrs(Path.t(), keyword()) :: map()
  def attrs(path, opts \\ []) do
    refs = List.wrap(opts[:refs])

    %{
      "work_dir" => Path.expand(path),
      "refs" => if(refs == [], do: nil, else: refs),
      "all_refs" => bool_attr(opts, :all_refs),
      "allow_shallow" => bool_attr(opts, :allow_shallow),
      "limit" => opts[:limit],
      "project_id" => opts[:project_id] || opts[:project],
      "name" => opts[:name],
      "slug" => opts[:slug]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp bool_attr(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      true -> true
      _other -> false
    end
  end

  defp do_wait(job_id, socket, deadline, timeout) do
    with {:ok, job} <- status(job_id, socket) do
      case job["status"] do
        status when status in ["completed", "failed"] ->
          {:ok, job}

        "running" ->
          deadline = if deadline == :queued, do: deadline_from(timeout), else: deadline
          continue(job_id, socket, deadline, timeout)

        _queued ->
          continue(job_id, socket, deadline, timeout)
      end
    end
  end

  defp continue(job_id, socket, deadline, timeout) do
    if deadline != :infinity and deadline != :queued and
         System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      Process.sleep(@poll_ms)
      do_wait(job_id, socket, deadline, timeout)
    end
  end

  defp deadline_from(:infinity), do: :infinity
  defp deadline_from(ms), do: System.monotonic_time(:millisecond) + ms

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(_body), do: "import request failed"
end
