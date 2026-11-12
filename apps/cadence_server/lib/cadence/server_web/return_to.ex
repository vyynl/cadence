defmodule Cadence.ServerWeb.ReturnTo do
  @moduledoc """
  Validates the post-login / post-ceremony return path.

  Only a local absolute path is accepted. `//host`, backslashes, control
  characters, and an auth page itself are rejected so the value can never
  become an open redirect or a loop.
  """

  @max_length 2048

  @doc "Returns a safe local path, or `\"/\"`."
  @spec safe(term()) :: String.t()
  def safe(value) when is_binary(value) do
    cond do
      value == "" -> "/"
      byte_size(value) > @max_length -> "/"
      not String.starts_with?(value, "/") -> "/"
      String.starts_with?(value, "//") -> "/"
      String.contains?(value, ["\\", "\n", "\r", <<0>>]) -> "/"
      auth_path?(value) -> "/"
      true -> value
    end
  end

  def safe(_value), do: "/"

  @doc "Stores a validated return path in the session for the next login."
  @spec store(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def store(conn, value) do
    case safe(value) do
      "/" -> conn
      path -> Plug.Conn.put_session(conn, :user_return_to, path)
    end
  end

  defp auth_path?(path) do
    String.starts_with?(path, "/sign-in") or String.starts_with?(path, "/auth/passkeys")
  end
end
