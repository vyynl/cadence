defmodule Cadence.ServerWeb.AccountSecurityHTML do
  @moduledoc """
  Templates for the account-security page (plan §7.7).
  """

  use Cadence.ServerWeb, :html

  import Cadence.ServerWeb.Presentation, only: [format_time: 1]

  embed_templates "account_security_html/*"

  @doc "Human hint for a credential's client-supplied transports."
  def key_hint(transports) when is_list(transports) do
    cond do
      "internal" in transports -> "Passkey on this device"
      "hybrid" in transports -> "Passkey on a phone or tablet"
      Enum.any?(transports, &(&1 in ["usb", "nfc", "ble"])) -> "Security key (USB/NFC)"
      true -> "Security key or passkey"
    end
  end

  def key_hint(_transports), do: "Security key or passkey"

  @doc "Last-used text; the timestamp is best-effort."
  def last_used(nil), do: "never used"
  def last_used(%DateTime{} = datetime), do: format_time(datetime)
end
