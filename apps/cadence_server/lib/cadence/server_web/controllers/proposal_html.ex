defmodule Cadence.ServerWeb.ProposalHTML do
  @moduledoc """
  Templates for the public proposal page.
  """

  use Cadence.ServerWeb, :html

  alias Cadence.ServerWeb.Components.Repo

  embed_templates "proposal_html/*"

  defp kind_title(:meld), do: "Meld proposal"
  defp kind_title(:promotion), do: "Promotion proposal"
  defp kind_title(_kind), do: "Proposal"

  defp short_token(token) when is_binary(token), do: String.slice(token, 0, 10)
  defp short_token(_token), do: ""

  defp format_flags([], false), do: "no flags"
  defp format_flags([], true), do: "pinned"

  defp format_flags(flags, pinned) do
    text = Enum.map_join(flags, ", ", &Atom.to_string/1)
    if pinned, do: text <> " · pinned", else: text
  end

  defp format_time(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
end
