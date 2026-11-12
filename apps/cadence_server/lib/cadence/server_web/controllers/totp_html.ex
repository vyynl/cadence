defmodule Cadence.ServerWeb.TotpHTML do
  @moduledoc false

  use Cadence.ServerWeb, :html

  embed_templates("totp_html/*")
end
