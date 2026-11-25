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

  @doc """
  Hub folder whose direct child directories are registered as projects.

  `nil` or an empty string disables auto-discovery.
  """
  @spec projects_root() :: String.t() | nil
  def projects_root do
    case Application.get_env(:cadence_daemon, :projects_root) do
      root when is_binary(root) and root != "" -> root
      _other -> nil
    end
  end

  @doc "Interval between hub rescans in milliseconds (default 30 s)."
  @spec projects_scan_interval_ms() :: pos_integer()
  def projects_scan_interval_ms do
    Application.get_env(:cadence_daemon, :projects_scan_interval_ms, 30_000)
    |> positive(30_000)
  end

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

  @doc """
  Maximum SHAs sent in one existence-handshake request.

  The daemon splits a batch's unique SHAs into chunks of this size and asks the
  server once per chunk. The server enforces the same cap per request, so a
  daemon value larger than the server's makes the handshake fall back to a full
  push. A non-positive value disables the handshake.
  """
  @spec sync_exists_limit() :: pos_integer()
  def sync_exists_limit do
    Application.get_env(:cadence_daemon, :sync_exists_limit, 5_000)
  end

  @doc "Extra `Req` options for sync HTTP calls (tests inject `Req.Test`)."
  @spec sync_req_options() :: keyword()
  def sync_req_options do
    Application.get_env(:cadence_daemon, :sync_req_options, [])
  end

  @doc """
  CA bundle trusted for the server connection in place of the system store
  (`CAD_SYNC_CA_FILE`), or `nil` for the system store.

  Set it when the server's certificate chains to a private CA: the bundled Caddy
  `internal` profile, a LAN install, or an inspecting proxy whose CA you accept.
  """
  @spec sync_ca_file() :: Path.t() | nil
  def sync_ca_file do
    Application.get_env(:cadence_daemon, :sync_ca_file)
  end

  @doc """
  Whether the daemon verifies the server's certificate (`CAD_SYNC_VERIFY_TLS`,
  default `true`, spec §12.6).

  `false` disables authentication of the server for both the sync HTTP client and
  the notification socket. It does not bypass a firewall that blocks the host,
  and it is logged at boot.
  """
  @spec sync_verify_tls?() :: boolean()
  def sync_verify_tls? do
    Application.get_env(:cadence_daemon, :sync_verify_tls, true)
  end

  @doc """
  TLS transport options for the server connection, shared by `Req` and
  `Slipstream`.

  Empty with the default configuration, so callers add nothing and the system
  store applies.
  """
  @spec sync_transport_opts() :: keyword()
  def sync_transport_opts do
    verify_opts = if sync_verify_tls?(), do: [], else: [verify: :verify_none]

    case sync_ca_file() do
      nil -> verify_opts
      path -> Keyword.put(verify_opts, :cacertfile, path)
    end
  end

  @doc """
  `connect_options` for `Req`, built from `sync_transport_opts/0`.

  Returns `[]` with the default configuration when the system store applies.
  """
  @spec sync_connect_options() :: keyword()
  def sync_connect_options do
    case sync_transport_opts() do
      [] -> []
      transport_opts -> [transport_opts: transport_opts]
    end
  end

  @doc "Whether doc automation is enabled (default `true`, spec §9)."
  @spec docs_enabled?() :: boolean()
  def docs_enabled?, do: Application.get_env(:cadence_daemon, :docs_enabled, true)

  @doc "Maximum time a doc-generation job waits for the LLM (default 30 s)."
  @spec docs_timeout_ms() :: pos_integer()
  def docs_timeout_ms, do: Application.get_env(:cadence_daemon, :docs_timeout_ms, 30_000)

  @doc "Doc-agent calls allowed per rate-limit window (default 5)."
  @spec docs_rate_limit() :: pos_integer()
  def docs_rate_limit, do: Application.get_env(:cadence_daemon, :docs_rate_limit, 5)

  @doc "Doc-agent rate-limit window in milliseconds (default 60 s)."
  @spec docs_rate_scale() :: pos_integer()
  def docs_rate_scale, do: Application.get_env(:cadence_daemon, :docs_rate_scale, 60_000)

  @doc "Attempts before a doc job is deferred (default 3)."
  @spec docs_retry_attempts() :: pos_integer()
  def docs_retry_attempts, do: Application.get_env(:cadence_daemon, :docs_retry_attempts, 3)

  @doc "Linear backoff base between doc-job retries (default 5 s)."
  @spec docs_retry_backoff_ms() :: non_neg_integer()
  def docs_retry_backoff_ms do
    Application.get_env(:cadence_daemon, :docs_retry_backoff_ms, 5_000)
  end

  @doc "Maximum file operations accepted from one doc generation (default 20)."
  @spec docs_max_ops() :: pos_integer()
  def docs_max_ops, do: Application.get_env(:cadence_daemon, :docs_max_ops, 20)

  @doc "Maximum number of files under `docs_dir` included in one doc job (default 200)."
  @spec docs_max_files() :: pos_integer()
  def docs_max_files, do: Application.get_env(:cadence_daemon, :docs_max_files, 200)

  @doc "Maximum content size per doc operation in bytes (default 256 KiB)."
  @spec docs_max_file_bytes() :: pos_integer()
  def docs_max_file_bytes do
    Application.get_env(:cadence_daemon, :docs_max_file_bytes, 262_144)
  end

  @doc "Shared prompt budget for the schema and current docs (default 64 KiB)."
  @spec docs_context_bytes() :: pos_integer()
  def docs_context_bytes do
    Application.get_env(:cadence_daemon, :docs_context_bytes, 65_536)
  end

  @doc "Maximum diff text sent to the doc model (default 32 KiB)."
  @spec docs_diff_max_bytes() :: pos_integer()
  def docs_diff_max_bytes do
    Application.get_env(:cadence_daemon, :docs_diff_max_bytes, 32_768)
  end

  @doc "Maximum commits one import may walk (default 2,000)."
  @spec import_max_commits() :: pos_integer()
  def import_max_commits do
    Application.get_env(:cadence_daemon, :import_max_commits, 2_000) |> positive(2_000)
  end

  @doc "Maximum blob size copied by an import in bytes (default 8 MiB; `0` disables)."
  @spec import_max_blob_bytes() :: non_neg_integer()
  def import_max_blob_bytes do
    Application.get_env(:cadence_daemon, :import_max_blob_bytes, 8_388_608)
    |> non_negative(8_388_608)
  end

  @doc "Wall-clock bound for one import job in seconds (default 1,800; `0` disables)."
  @spec import_max_seconds() :: non_neg_integer()
  def import_max_seconds do
    Application.get_env(:cadence_daemon, :import_max_seconds, 1_800) |> non_negative(1_800)
  end

  @doc "Whether a shallow clone may be imported (default `false`)."
  @spec import_allow_shallow?() :: boolean()
  def import_allow_shallow? do
    Application.get_env(:cadence_daemon, :import_allow_shallow, false) == true
  end

  @doc "Nodes inserted and enqueued per transaction batch during an import (default 100)."
  @spec import_push_batch() :: pos_integer()
  def import_push_batch do
    Application.get_env(:cadence_daemon, :import_push_batch, 100) |> positive(100)
  end

  # A typo in an env var must not disable a bound: fall back to the default.
  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp non_negative(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value, default), do: default
end
