defmodule Cadence.ServerWeb.Layouts do
  @moduledoc """
  Server-rendered layouts for the web UI.
  """

  use Cadence.ServerWeb, :html

  embed_templates "layouts/*"
end
