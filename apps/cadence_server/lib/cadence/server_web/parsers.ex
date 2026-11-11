defmodule Cadence.ServerWeb.Parsers do
  @moduledoc """
  Endpoint body parsers with a sync-scoped size limit.

  Browser and public routes keep `Plug.Parsers`' default 8 MiB limit. Requests
  under `/sync` are parsed with `CAD_SYNC_MAX_BODY_BYTES` (default 64 MiB) so a
  pushed node carrying a moderately large tree can be accepted (spec §10.2).

  The sync limit is runtime configuration, so it is resolved in `call/2` rather
  than `init/1`: Phoenix initializes endpoint plugs at compile time.
  """

  @behaviour Plug

  @parsers [:urlencoded, :multipart, :json]
  @default_sync_max_body_bytes 64 * 1024 * 1024

  @impl Plug
  def init(_opts), do: Plug.Parsers.init(parsers: @parsers, pass: ["*/*"], json_decoder: Jason)

  @impl Plug
  def call(conn, default_parsers) do
    parsers =
      if sync_request?(conn) do
        Plug.Parsers.init(
          parsers: @parsers,
          pass: ["*/*"],
          json_decoder: Jason,
          length: sync_max_body_bytes()
        )
      else
        default_parsers
      end

    Plug.Parsers.call(conn, parsers)
  end

  @doc """
  The configured sync body limit, falling back to 64 MiB for an absent,
  non-integer, or non-positive value so a typo cannot disable sync entirely.
  """
  @spec sync_max_body_bytes() :: pos_integer()
  def sync_max_body_bytes do
    case Application.get_env(:cadence_server, :sync_max_body_bytes) do
      limit when is_integer(limit) and limit > 0 -> limit
      _limit -> @default_sync_max_body_bytes
    end
  end

  defp sync_request?(%Plug.Conn{path_info: ["sync" | _rest]}), do: true
  defp sync_request?(_conn), do: false
end
