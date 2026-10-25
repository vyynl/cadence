defmodule Cadence.ServerWeb.ProjectHTML do
  @moduledoc """
  Templates for public project pages.
  """

  use Cadence.ServerWeb, :html

  embed_templates "project_html/*"

  def format_flags([]), do: "none"
  def format_flags(flags), do: Enum.map_join(flags, ", ", &Atom.to_string/1)

  def format_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end
end
