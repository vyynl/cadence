defmodule Cadence.Server.AuthRateLimit do
  @moduledoc """
  Password and TOTP rate limits (spec §7.4).

  Backed by Hammer's ETS fix-window. Limits and windows are read at call time
  so a non-positive value disables a bound without a restart:

    * login per client IP (`CAD_AUTH_LOGIN_IP_RATE_LIMIT`)
    * login per IP + email (`CAD_AUTH_LOGIN_ACCOUNT_RATE_LIMIT`)
    * TOTP verification per user (`CAD_AUTH_TOTP_RATE_LIMIT`)

  Keys are deliberately coarse so a caller cannot enumerate accounts through
  timing or error differences.
  """

  use Hammer, backend: :ets, algorithm: :fix_window

  @doc "Whether a password attempt is allowed for this IP and email."
  @spec allow_login?(String.t(), String.t()) :: boolean()
  def allow_login?(client_ip, email) do
    allow?({:login_ip, client_ip}, login_scale(), login_ip_limit()) and
      allow?(
        {:login_account, client_ip, String.downcase(String.trim(email))},
        login_scale(),
        login_account_limit()
      )
  end

  @doc "Whether a TOTP/recovery verification is allowed for this user."
  @spec allow_totp?(term()) :: boolean()
  def allow_totp?(user_id) do
    allow?({:totp, user_id}, totp_scale(), totp_limit())
  end

  defp allow?(_key, _scale, limit) when not is_integer(limit) or limit <= 0, do: true

  defp allow?(key, scale, limit) do
    match?({:allow, _count}, hit(key, scale, limit))
  end

  defp login_ip_limit, do: int_env(:auth_login_ip_rate_limit, 20)
  defp login_account_limit, do: int_env(:auth_login_account_rate_limit, 5)
  defp login_scale, do: int_env(:auth_login_rate_scale, 60_000)
  defp totp_limit, do: int_env(:auth_totp_rate_limit, 10)
  defp totp_scale, do: int_env(:auth_totp_rate_scale, 300_000)

  defp int_env(key, default) do
    case Application.get_env(:cadence_server, key, default) do
      value when is_integer(value) -> value
      _other -> default
    end
  end
end
