defmodule Cadence.ServerWeb.AccountLiveTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.LocalAuth
  alias Cadence.Server.Accounts.TOTP
  alias Cadence.Server.Accounts.User
  alias Cadence.Server.Accounts.UserSession
  alias Cadence.Server.Repo
  alias Cadence.ServerWeb.PasskeyTestHelpers, as: H

  @password "correct horse battery staple"
  @new_password "an entirely different password"

  setup do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      LocalAuth.create_user(%{
        email: "account-#{suffix}@example.com",
        name: "Account User",
        password: @password
      })

    {:ok, user: user}
  end

  test "/account requires a session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/account")
  end

  test "a fresh session sees the account sections and links", %{conn: conn, user: user} do
    {:ok, view, _html} = conn |> H.signed_conn(user) |> live("/account")
    html = render_async(view)

    assert html =~ to_string(user.email)
    assert html =~ "Change password"
    assert html =~ "Two-factor authentication"
    assert html =~ "/account/security"
    assert html =~ "/auth/tokens/new"
    assert html =~ "Daemon tokens"
    assert html =~ "No daemon tokens yet."
  end

  test "lists the account's daemon tokens and hides other accounts' tokens", %{
    conn: conn,
    user: user
  } do
    assert {:ok, _} = Accounts.create_api_key(user, "laptop-token")

    {:ok, other} =
      LocalAuth.create_user(%{
        email: "other-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    assert {:ok, _} = Accounts.create_api_key(other, "not-yours-token")

    {:ok, view, _html} = conn |> H.signed_conn(user) |> live("/account")
    html = render_async(view)

    assert html =~ "laptop-token"
    refute html =~ "not-yours-token"
    assert html =~ "no expiry"
  end

  test "an expired or unnamed token still lists with an honest label", %{
    conn: conn,
    user: user
  } do
    expires_at = DateTime.add(DateTime.utc_now(), -60, :second)

    assert {:ok, expired} =
             Ash.create(
               Cadence.Server.Accounts.ApiKey,
               %{user_id: user.id, name: "old-laptop", expires_at: expires_at},
               action: :create
             )

    assert {:ok, unnamed} = Accounts.create_api_key(user, "   ")

    {:ok, view, _html} = conn |> H.signed_conn(user) |> live("/account")
    html = render_async(view)

    assert html =~ "old-laptop"
    assert html =~ "expired "
    assert html =~ "phx-value-id=\"#{expired.id}\""
    assert html =~ "Unnamed token"
    assert html =~ "phx-value-id=\"#{unnamed.id}\""
    assert html =~ "no expiry"
  end

  test "revoking a token deletes it, clears the row, and rejects the key", %{
    conn: conn,
    user: user
  } do
    assert {:ok, api_key} = Accounts.create_api_key(user, "revoke-me")
    plaintext = api_key.__metadata__.plaintext_api_key

    {:ok, view, _html} = conn |> H.signed_conn(user) |> live("/account")
    assert render_async(view) =~ "revoke-me"

    view
    |> element("button[phx-click=\"revoke_token\"][phx-value-id=\"#{api_key.id}\"]")
    |> render_click()

    html = render_async(view)
    refute html =~ "revoke-me"
    assert html =~ "Daemon token revoked"
    assert html =~ "No daemon tokens yet."

    refute_api_key(api_key.id)
    assert {:error, :invalid_api_key} = Accounts.authenticate_api_key(plaintext)
  end

  test "revoking another account's token is refused and changes nothing", %{
    conn: conn,
    user: user
  } do
    {:ok, other} =
      LocalAuth.create_user(%{
        email: "foreign-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    assert {:ok, foreign} = Accounts.create_api_key(other, "foreign-token")

    {:ok, view, _html} = conn |> H.signed_conn(user) |> live("/account")
    render_async(view)

    html = render_click(view, "revoke_token", %{"id" => foreign.id})

    assert html =~ "That daemon token could not be found."
    refute html =~ "foreign-token"

    assert {:ok, %Cadence.Server.Accounts.ApiKey{}} =
             Ash.get(Cadence.Server.Accounts.ApiKey, foreign.id, domain: Accounts)
  end

  test "a malformed revoke event flashes without crashing", %{conn: conn, user: user} do
    {:ok, view, _html} = conn |> H.signed_conn(user) |> live("/account")
    render_async(view)

    html = render_click(view, "revoke_token", %{})

    assert html =~ "That daemon token could not be found."
  end

  test "a stale session is redirected to sudo re-authentication", %{conn: conn, user: user} do
    conn = H.signed_conn(conn, user)

    Repo.update_all(
      from(s in UserSession, where: s.user_id == ^user.id),
      set: [authenticated_at: DateTime.add(DateTime.utc_now(), -30, :minute)]
    )

    assert {:error, {:redirect, %{to: "/sign-in?sudo=1&return_to=/account"}}} =
             live(conn, "/account")
  end

  test "changing the password keeps the current session and revokes the others", %{
    conn: conn,
    user: user
  } do
    conn = H.signed_conn(conn, user)
    {_other_conn, _session} = Cadence.ServerWeb.UserAuth.log_in(conn, user)
    assert Repo.aggregate(from(s in UserSession, where: s.user_id == ^user.id), :count) == 2

    {:ok, view, _html} = live(conn, "/account")

    view
    |> form("#password-form", %{
      "password" => %{"password" => @new_password, "password_confirmation" => @new_password}
    })
    |> render_submit()

    assert render(view) =~ "Password updated. Other sessions were signed out."
    assert Repo.aggregate(from(s in UserSession, where: s.user_id == ^user.id), :count) == 1
    refute LocalAuth.get_user_by_email_and_password(to_string(user.email), @password)
    assert LocalAuth.get_user_by_email_and_password(to_string(user.email), @new_password)
  end

  test "a mismatched password shows the policy copy", %{conn: conn, user: user} do
    {:ok, view, _html} = conn |> H.signed_conn(user) |> live("/account")

    view
    |> form("#password-form", %{
      "password" => %{"password" => @new_password, "password_confirmation" => "different"}
    })
    |> render_submit()

    assert render(view) =~ "The passwords do not match."
  end

  test "starting TOTP enrollment renders a QR code and confirming enables it", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = conn |> H.signed_conn(user) |> live("/account")
    render_async(view)

    view
    |> element("button[phx-click=\"start_totp\"]")
    |> render_click()

    html = render(view)
    assert html =~ "Scan this QR code"
    assert html =~ "data:image/svg+xml;base64,"

    {:ok, pending} = Ash.get(User, user.id, domain: Accounts)
    {:ok, secret} = TOTP.get_secret(pending)

    view
    |> form("#confirm-totp-form", %{"code" => NimbleTOTP.verification_code(secret)})
    |> render_submit()

    html = render(view)
    assert html =~ "Save your recovery codes"
    assert length(Regex.scan(~r/<code>/, html)) == 10

    {:ok, enrolled} = Ash.get(User, user.id, domain: Accounts)
    assert TOTP.enabled?(enrolled)
    assert TOTP.count_unused(enrolled) == 10
  end

  test "regenerating and disabling TOTP require a current code", %{conn: conn, user: user} do
    {user, secret} = enrolled_user(user)
    {:ok, view, _html} = conn |> H.signed_conn(user) |> live("/account")
    render_async(view)

    view
    |> form("#regenerate-form", %{"code" => NimbleTOTP.verification_code(secret)})
    |> render_submit()

    assert render(view) =~ "New recovery codes generated"

    # The code was consumed by the regenerate verification; age the last use
    # before disabling with the next valid code.
    {:ok, aged} =
      Ash.get!(User, user.id, domain: Accounts)
      |> Ash.Changeset.for_update(:mark_totp_used, %{
        totp_last_used_at: DateTime.utc_now() |> DateTime.add(-60, :second)
      })
      |> Ash.update(domain: Accounts)

    view
    |> form("#disable-totp-form", %{"code" => NimbleTOTP.verification_code(secret)})
    |> render_submit()

    # The account sections reload with assign_async; wait for that render
    # instead of racing it on a slower runner.
    assert render_async(view) =~ "TOTP is not enabled."
    {:ok, disabled} = Ash.get(User, aged.id, domain: Accounts)
    refute TOTP.enabled?(disabled)
  end

  test "sign out everywhere removes every session and redirects", %{conn: conn, user: user} do
    conn = H.signed_conn(conn, user)
    {_other_conn, _session} = Cadence.ServerWeb.UserAuth.log_in(conn, user)

    {:ok, view, _html} = live(conn, "/account")
    render_async(view)

    view
    |> element("button[phx-click=\"sign_out_everywhere\"]")
    |> render_click()

    assert_redirect(view, "/sign-in")
    assert Repo.aggregate(from(s in UserSession, where: s.user_id == ^user.id), :count) == 0
  end

  # `Ash.get/3` reports a missing row as a NotFound error tuple; pin the exact
  # shape so a storage failure cannot pass for a successful revoke.
  defp refute_api_key(id) do
    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             Ash.get(Cadence.Server.Accounts.ApiKey, id, domain: Accounts)
  end

  defp enrolled_user(user) do
    {:ok, user, secret} = TOTP.begin_enrollment(user)
    {:ok, user, _codes} = TOTP.confirm_enrollment(user, NimbleTOTP.verification_code(secret))

    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    {:ok, user} =
      user
      |> Ash.Changeset.for_update(:mark_totp_used, %{totp_last_used_at: past})
      |> Ash.update(domain: Accounts)

    {user, secret}
  end
end
