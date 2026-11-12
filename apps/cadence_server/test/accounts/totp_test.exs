defmodule Cadence.Server.Accounts.TOTPTest do
  use ExUnit.Case, async: false

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.LocalAuth
  alias Cadence.Server.Accounts.TOTP
  alias Cadence.Server.Accounts.User
  alias Cadence.Server.Security.SecretBox

  @password "correct horse battery staple"

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Cadence.Server.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "enrollment is a compare-and-set: two callers converge on one secret" do
    user = local_user("cas")

    assert {:ok, first_user, first_secret} = TOTP.begin_enrollment(user)
    assert {:ok, second_user, second_secret} = TOTP.begin_enrollment(user)

    assert first_secret == second_secret
    assert first_user.totp_secret == second_user.totp_secret
    refute TOTP.enabled?(first_user)
  end

  test "confirming enrollment stores the secret and returns ten recovery codes" do
    user = local_user("confirm")
    assert {:ok, user, secret} = TOTP.begin_enrollment(user)

    code = NimbleTOTP.verification_code(secret)
    assert {:ok, confirmed, codes} = TOTP.confirm_enrollment(user, code)

    assert TOTP.enabled?(confirmed)
    assert length(codes) == 10
    assert length(Enum.uniq(codes)) == 10
    assert TOTP.count_unused(confirmed) == 10
    assert {:ok, ^secret} = TOTP.get_secret(confirmed)
  end

  test "a wrong code does not confirm" do
    user = local_user("wrong")
    assert {:ok, user, _secret} = TOTP.begin_enrollment(user)

    assert {:error, :invalid_code} = TOTP.confirm_enrollment(user, "000000")
    assert {:error, :not_started} = TOTP.confirm_enrollment(%{user | totp_secret: nil}, "000000")
  end

  test "a confirmed code cannot be replayed in the same period" do
    {user, secret, codes} = enabled_user("replay")
    code = Enum.at(codes, 0)
    assert is_binary(code)

    # Enrollment consumed the current step; the same step is rejected.
    assert TOTP.verify(user, NimbleTOTP.verification_code(secret)) == :error
  end

  test "a fresh period accepts the code and records the step" do
    {user, secret, _codes} = enabled_user("fresh")

    # Pretend the last accepted step was a minute ago.
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    {:ok, aged} =
      user
      |> Ash.Changeset.for_update(:mark_totp_used, %{totp_last_used_at: past})
      |> Ash.update(domain: Accounts)

    assert TOTP.verify(aged, NimbleTOTP.verification_code(secret)) == :ok
    assert {:ok, reloaded} = Ash.get(User, aged.id, domain: Accounts)
    assert DateTime.compare(reloaded.totp_last_used_at, past) == :gt
  end

  test "recovery codes are single use and matched after normalization" do
    {user, _secret, codes} = enabled_user("recovery")
    code = Enum.at(codes, 3)
    spaced = " " <> String.downcase(String.replace(code, "-", " "))

    assert {:ok, _user} = TOTP.consume_recovery_code(user, spaced)
    assert TOTP.consume_recovery_code(user, code) == :error
    assert TOTP.count_unused(user) == 9
  end

  test "verify_login falls back to a recovery code" do
    {user, _secret, codes} = enabled_user("fallback")

    assert TOTP.verify_login(user, Enum.at(codes, 0)) == {:ok, :recovery}
    assert TOTP.verify_login(user, "000000") == :error
  end

  test "regenerating codes invalidates the old set" do
    {user, _secret, old_codes} = enabled_user("regen")

    assert {:ok, new_codes} = TOTP.regenerate_recovery_codes(user)
    assert length(new_codes) == 10
    assert TOTP.consume_recovery_code(user, Enum.at(old_codes, 0)) == :error
    assert {:ok, _user} = TOTP.consume_recovery_code(user, Enum.at(new_codes, 0))
  end

  test "disabling clears the secret and every code" do
    {user, _secret, codes} = enabled_user("disable")

    assert {:ok, disabled} = TOTP.disable(user)
    refute TOTP.enabled?(disabled)
    assert TOTP.count_unused(disabled) == 0
    assert TOTP.get_secret(disabled) == :error
    assert TOTP.consume_recovery_code(user, Enum.at(codes, 0)) == :error
  end

  test "an unreadable unconfirmed secret is healed; a confirmed one is not" do
    user = local_user("heal")

    {:ok, user} =
      user
      |> Ash.Changeset.for_update(:confirm_totp, %{
        totp_secret: "not-a-secret-box-value",
        totp_confirmed_at: nil,
        totp_last_used_at: nil
      })
      |> Ash.update(domain: Accounts)

    assert {:ok, healed, secret} = TOTP.begin_enrollment(user)
    assert is_binary(secret)
    assert {:ok, _} = SecretBox.decrypt(healed.totp_secret)

    {:ok, confirmed, _codes} =
      case TOTP.confirm_enrollment(healed, NimbleTOTP.verification_code(secret)) do
        {:ok, confirmed, codes} -> {:ok, confirmed, codes}
      end

    {:ok, broken} =
      confirmed
      |> Ash.Changeset.for_update(:confirm_totp, %{totp_secret: "not-a-secret-box-value"})
      |> Ash.update(domain: Accounts)

    assert TOTP.begin_enrollment(broken) == :error
  end

  test "enrollment helpers render a URI, a QR data URI, and a grouped secret" do
    user = local_user("render")
    secret = NimbleTOTP.secret()

    assert TOTP.otpauth_uri(user, secret) =~ "otpauth://totp/"
    assert TOTP.otpauth_uri(user, secret) =~ "issuer=Cadence%20Test"
    assert "data:image/svg+xml;base64," <> _ = TOTP.qr_data_uri(user, secret)
    assert TOTP.format_secret(secret) =~ ~r/^[A-Z2-7 ]+$/
  end

  defp local_user(prefix) do
    {:ok, user} =
      LocalAuth.create_user(%{
        email: "#{prefix}-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp enabled_user(prefix) do
    user = local_user(prefix)
    {:ok, user, secret} = TOTP.begin_enrollment(user)
    {:ok, confirmed, codes} = TOTP.confirm_enrollment(user, NimbleTOTP.verification_code(secret))
    {confirmed, secret, codes}
  end
end
