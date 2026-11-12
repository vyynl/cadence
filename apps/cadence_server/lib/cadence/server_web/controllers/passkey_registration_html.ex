defmodule Cadence.ServerWeb.PasskeyRegistrationHTML do
  @moduledoc """
  Templates for the passkey registration ceremony (plan §7.5).
  """

  use Cadence.ServerWeb, :html

  embed_templates "passkey_registration_html/*"
end
