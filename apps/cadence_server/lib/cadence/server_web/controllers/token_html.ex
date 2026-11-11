defmodule Cadence.ServerWeb.TokenHTML do
  @moduledoc """
  Templates for personal access token issuance.

  These pages deliberately render without the app layout: the plaintext key is
  shown exactly once on a bare page, so it is never embedded in a page that
  also loads the site's scripts.
  """

  use Cadence.ServerWeb, :html

  embed_templates "token_html/*"
end
