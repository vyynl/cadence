defmodule Cadence.ServerWeb.Metadata do
  @moduledoc """
  Canonical URL and metadata helpers for public pages.
  """

  @default_description "Cadence — local-first project history, readable in the browser."

  @doc "Canonical public base URL, without a trailing slash."
  @spec public_url() :: String.t()
  def public_url do
    url = Application.get_env(:cadence_server, :public_url) || "http://localhost"
    String.trim_trailing(url, "/")
  end

  @doc "Build an absolute canonical URL for a path."
  @spec canonical(String.t() | nil) :: String.t()
  def canonical(path) when path in [nil, ""], do: public_url() <> "/"
  def canonical(path) when is_binary(path), do: public_url() <> ensure_leading_slash(path)

  @doc "Default description for pages without a more specific one."
  @spec default_description() :: String.t()
  def default_description, do: @default_description

  defp ensure_leading_slash("/" <> _rest = path), do: path
  defp ensure_leading_slash(path), do: "/" <> path
end
