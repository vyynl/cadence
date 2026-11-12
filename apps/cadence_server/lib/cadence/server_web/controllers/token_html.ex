defmodule Cadence.ServerWeb.TokenHTML do
  @moduledoc """
  Templates for personal access token issuance.

  These pages render through the app layout for consistent styling, but the
  controller disables the layout's JavaScript (`load_app_scripts: false`): the
  plaintext key is shown exactly once and never shares a document with the
  site's scripts.
  """

  use Cadence.ServerWeb, :html

  embed_templates "token_html/*"
end
