defmodule Cadence.Daemon.Env do
  @moduledoc """
  Reads daemon runtime configuration.

  Populated from `CAD_*` env vars in `config/runtime.exs`; this module provides
  the typed accessors and defaults so callers don't each reach into
  `Application.get_env/3`.
  """

  @doc "The local user's UUID, used as a node's `created_by` and the owner id."
  @spec local_user_id() :: Ecto.UUID.t() | nil
  def local_user_id, do: Application.get_env(:cadence_daemon, :local_user_id)

  @doc "Entry names skipped when snapshotting a working tree (`.git` is always skipped)."
  @spec ignore_names() :: [String.t()]
  def ignore_names, do: Application.get_env(:cadence_daemon, :ignore, [])

  @doc "Git author identity used for local commit objects."
  @spec git_author() :: %{name: String.t(), email: String.t()}
  def git_author do
    Application.get_env(:cadence_daemon, :git_author, %{
      name: "cadence",
      email: "cadence@local"
    })
  end

  @doc "Maximum number of files returned by a node diff."
  @spec diff_max_files() :: non_neg_integer()
  def diff_max_files, do: Application.get_env(:cadence_daemon, :diff_max_files, 20)

  @doc "Maximum number of diff lines returned per file."
  @spec diff_max_lines_per_file() :: non_neg_integer()
  def diff_max_lines_per_file do
    Application.get_env(:cadence_daemon, :diff_max_lines_per_file, 400)
  end

  @doc "Maximum combined file size diffed for a hover preview."
  @spec diff_max_bytes() :: non_neg_integer()
  def diff_max_bytes do
    Application.get_env(:cadence_daemon, :diff_max_bytes, 262_144)
  end

  @doc "Cloud sync target URL, or `nil` when offline."
  @spec server_url() :: String.t() | nil
  def server_url, do: Application.get_env(:cadence_daemon, :server_url)

  @doc "Daemon bearer token, or `nil` when offline."
  @spec auth_token() :: String.t() | nil
  def auth_token, do: Application.get_env(:cadence_daemon, :auth_token)

  @doc "Whether automatic sync is enabled (default `true`)."
  @spec sync_enabled?() :: boolean()
  def sync_enabled?, do: Application.get_env(:cadence_daemon, :sync_enabled, true)

  @doc "Whether the optional notification channel is enabled (default `true`)."
  @spec sync_channel_enabled?() :: boolean()
  def sync_channel_enabled? do
    Application.get_env(:cadence_daemon, :sync_channel_enabled, true)
  end

  @doc "The websocket URL derived from `server_url`, or `nil` when offline."
  @spec sync_socket_url() :: String.t() | nil
  def sync_socket_url do
    case server_url() do
      url when is_binary(url) and url != "" ->
        uri = URI.parse(url)

        scheme =
          case uri.scheme do
            "http" -> "ws"
            "https" -> "wss"
            other -> other
          end

        %{uri | scheme: scheme, path: "/socket/websocket", query: nil, fragment: nil}
        |> URI.to_string()

      _ ->
        nil
    end
  end

  @doc "Background HTTP request timeout in milliseconds."
  @spec sync_request_timeout_ms() :: pos_integer()
  def sync_request_timeout_ms do
    Application.get_env(:cadence_daemon, :sync_request_timeout_ms, 5_000)
  end

  @doc """
  HTTP timeout for a synchronous union request.

  A conflicted union can take `(meld retries + 1) × server timeout + backoff` on the
  server (about 120.5 s at defaults), so this is deliberately larger than
  `sync_request_timeout_ms/0`.
  """
  @spec sync_union_timeout_ms() :: pos_integer()
  def sync_union_timeout_ms do
    Application.get_env(:cadence_daemon, :sync_union_timeout_ms, 180_000)
  end

  @doc "Delay between background sync passes in milliseconds."
  @spec sync_interval_ms() :: pos_integer()
  def sync_interval_ms do
    Application.get_env(:cadence_daemon, :sync_interval_ms, 30_000)
  end

  @doc "Base delay before retrying a failed sync operation."
  @spec sync_retry_backoff_ms() :: non_neg_integer()
  def sync_retry_backoff_ms do
    Application.get_env(:cadence_daemon, :sync_retry_backoff_ms, 30_000)
  end

  @doc "Maximum automatic retry attempts for a pending node."
  @spec sync_max_attempts() :: pos_integer()
  def sync_max_attempts do
    Application.get_env(:cadence_daemon, :sync_max_attempts, 10)
  end

  @doc "Maximum number of nodes sent in one push batch."
  @spec sync_push_limit() :: pos_integer()
  def sync_push_limit do
    Application.get_env(:cadence_daemon, :sync_push_limit, 100)
  end

  @doc "Extra `Req` options for sync HTTP calls (tests inject `Req.Test`)."
  @spec sync_req_options() :: keyword()
  def sync_req_options do
    Application.get_env(:cadence_daemon, :sync_req_options, [])
  end
end
