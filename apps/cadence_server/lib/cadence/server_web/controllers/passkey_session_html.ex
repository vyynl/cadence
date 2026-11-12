defmodule Cadence.ServerWeb.PasskeySessionHTML do
  @moduledoc """
  Templates for the passkey sign-in ceremony (plan §7.6).
  """

  use Cadence.ServerWeb, :html

  embed_templates "passkey_session_html/*"
end
