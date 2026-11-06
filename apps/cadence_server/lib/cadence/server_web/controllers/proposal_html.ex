defmodule Cadence.ServerWeb.ProposalHTML do
  @moduledoc """
  Templates for the public proposal page.
  """

  use Cadence.ServerWeb, :html

  alias Cadence.ServerWeb.Components.Repo
  alias Cadence.ServerWeb.Presentation

  embed_templates "proposal_html/*"

  defp short_token(token) when is_binary(token), do: String.slice(token, 0, 10)
  defp short_token(_token), do: ""
end
