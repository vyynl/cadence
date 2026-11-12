defmodule Cadence.ServerWeb.AccountLive.Settings do
  @moduledoc """
  Account settings (spec §7.4): email, local password, mandatory TOTP
  management, recovery codes, and session revocation.

  The route is behind `:require_sudo_mode`, and every event re-checks the sudo
  window before touching credentials. TOTP and recovery-code submissions also
  share the per-user verification limit.
  """

  use Cadence.ServerWeb, :live_view

  alias Cadence.Server.Accounts.LocalAuth
  alias Cadence.Server.Accounts.TOTP
  alias Cadence.Server.AuthRateLimit
  alias Cadence.Server.Passkeys.Config
  alias Cadence.ServerWeb.UserAuth

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Account · Cadence")
      |> assign(:enrollment, nil)
      |> assign(:recovery_codes, nil)
      |> assign(:form, to_form(%{"password" => "", "password_confirmation" => ""}, as: :password))

    {:ok, refresh_account(socket)}
  end

  @impl true
  def handle_event("change_password", %{"password" => params}, socket) do
    with_sudo(socket, fn socket, user ->
      password = Map.get(params, "password", "")
      confirmation = Map.get(params, "password_confirmation", "")

      case LocalAuth.set_password(user, password, confirmation) do
        {:ok, _updated} ->
          UserAuth.revoke_all_except(user.id, socket.assigns.current_session.id)

          {:noreply,
           socket
           |> put_flash(:info, "Password updated. Other sessions were signed out.")
           |> assign(
             :form,
             to_form(%{"password" => "", "password_confirmation" => ""}, as: :password)
           )}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, password_error(error))}
      end
    end)
  end

  def handle_event("start_totp", _params, socket) do
    with_sudo(socket, fn socket, user ->
      if TOTP.enabled?(user) do
        {:noreply, put_flash(socket, :info, "Two-factor authentication is already enabled.")}
      else
        case TOTP.begin_enrollment(user) do
          {:ok, user, secret} ->
            {:noreply,
             socket
             |> assign(:current_user, user)
             |> assign(:enrollment, %{
               secret: TOTP.format_secret(secret),
               qr_data_uri: TOTP.qr_data_uri(user, secret),
               error: nil
             })}

          :error ->
            {:noreply, put_flash(socket, :error, "Could not start enrollment. Try again.")}
        end
      end
    end)
  end

  def handle_event("confirm_totp", %{"code" => code}, socket) do
    with_sudo(socket, fn socket, user ->
      if AuthRateLimit.allow_totp?(user.id) do
        case TOTP.confirm_enrollment(user, code) do
          {:ok, user, codes} ->
            {:noreply,
             socket
             |> assign(:current_user, user)
             |> assign(:enrollment, nil)
             |> assign(:recovery_codes, codes)
             |> put_flash(:info, "Two-factor authentication enabled.")
             |> refresh_account()}

          {:error, :invalid_code} ->
            {:noreply, put_enrollment_error(socket, user, "That code is not valid.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not enable two-factor authentication.")}
        end
      else
        {:noreply, put_flash(socket, :error, "Too many attempts. Try again later.")}
      end
    end)
  end

  def handle_event("regenerate_recovery_codes", %{"code" => code}, socket) do
    with_sudo(socket, fn socket, user ->
      cond do
        not AuthRateLimit.allow_totp?(user.id) ->
          {:noreply, put_flash(socket, :error, "Too many attempts. Try again later.")}

        TOTP.verify(user, code) != :ok ->
          {:noreply, put_flash(socket, :error, "That code is not valid.")}

        true ->
          case TOTP.regenerate_recovery_codes(user) do
            {:ok, codes} ->
              {:noreply,
               socket
               |> assign(:recovery_codes, codes)
               |> put_flash(:info, "New recovery codes generated. Old codes no longer work.")
               |> refresh_account()}

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "Could not generate recovery codes.")}
          end
      end
    end)
  end

  def handle_event("disable_totp", %{"code" => code}, socket) do
    with_sudo(socket, fn socket, user ->
      cond do
        not AuthRateLimit.allow_totp?(user.id) ->
          {:noreply, put_flash(socket, :error, "Too many attempts. Try again later.")}

        TOTP.verify(user, code) != :ok ->
          {:noreply, put_flash(socket, :error, "That code is not valid.")}

        true ->
          case TOTP.disable(user) do
            {:ok, updated} ->
              {:noreply,
               socket
               |> assign(:current_user, updated)
               |> assign(:recovery_codes, nil)
               |> put_flash(
                 :info,
                 "Two-factor authentication disabled. Password sign-in will require enrollment again."
               )
               |> refresh_account()}

            {:error, _reason} ->
              {:noreply,
               put_flash(socket, :error, "Could not disable two-factor authentication.")}
          end
      end
    end)
  end

  def handle_event("sign_out_everywhere", _params, socket) do
    with_sudo(socket, fn socket, user ->
      UserAuth.revoke_all(user.id)

      {:noreply,
       socket
       |> put_flash(:info, "Signed out of every session.")
       |> push_navigate(to: "/sign-in")}
    end)
  end

  def handle_event("reload_account", _params, socket) do
    {:noreply, refresh_account(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="account-page">
      <header class="account-header">
        <h1>Account</h1>
        <p class="auth-lede">Manage the credentials for this Cadence account.</p>
      </header>

      <section class="account-card">
        <h2>Email</h2>
        <p class="account-value">{to_string(@current_user.email)}</p>
        <p class="auth-note">Accounts are created and reset by the operator.</p>
      </section>

      <section class="account-card">
        <h2>Password</h2>
        <p :if={@current_user.hashed_password} class="account-value">
          A local password is set.
        </p>
        <p :if={!@current_user.hashed_password} class="account-value">
          No local password is set. OAuth and passkeys are the current sign-in methods.
        </p>

        <.form for={@form} id="password-form" phx-submit="change_password" class="account-form">
          <label class="auth-field">
            <span>New password</span>
            <input type="password" name="password[password]" autocomplete="new-password" required />
          </label>
          <label class="auth-field">
            <span>Confirm new password</span>
            <input
              type="password"
              name="password[password_confirmation]"
              autocomplete="new-password"
              required
            />
          </label>
          <button type="submit" class="admin-button button-primary">
            {if @current_user.hashed_password, do: "Change password", else: "Set password"}
          </button>
        </.form>
        <p class="auth-note">At least 12 characters. Other sessions are signed out.</p>
      </section>

      <section class="account-card">
        <h2>Two-factor authentication</h2>

        <%= cond do %>
          <% @recovery_count.loading -> %>
            <p class="auth-note">Loading…</p>
          <% @recovery_count.failed -> %>
            <p class="auth-error" role="alert">Could not load the account state.</p>
            <button class="admin-button" phx-click="reload_account">Try again</button>
          <% TOTP.enabled?(@current_user) -> %>
            <p class="account-value">
              TOTP is enabled. {recovery_count_label(@recovery_count.result)}
            </p>

            <form id="regenerate-form" phx-submit="regenerate_recovery_codes" class="account-form">
              <label class="auth-field">
                <span>Current code to regenerate recovery codes</span>
                <input
                  type="text"
                  name="code"
                  inputmode="numeric"
                  autocomplete="one-time-code"
                  spellcheck="false"
                  class="totp-code"
                  required
                />
              </label>
              <button type="submit" class="admin-button">Regenerate recovery codes</button>
            </form>

            <form id="disable-totp-form" phx-submit="disable_totp" class="account-form">
              <label class="auth-field">
                <span>Current code to disable TOTP</span>
                <input
                  type="text"
                  name="code"
                  inputmode="numeric"
                  autocomplete="one-time-code"
                  spellcheck="false"
                  class="totp-code"
                  required
                />
              </label>
              <button type="submit" class="admin-button button-warning">Disable TOTP</button>
            </form>
          <% @enrollment -> %>
            <div class="totp-step">
              <h3>1. Scan this QR code</h3>
              <img
                :if={@enrollment.qr_data_uri}
                src={@enrollment.qr_data_uri}
                alt="TOTP enrollment QR code"
                class="totp-qr"
              />
              <p class="auth-note">Or enter this secret manually:</p>
              <code class="totp-secret">{@enrollment.secret}</code>
            </div>
            <p :if={@enrollment.error} class="auth-error" role="alert">{@enrollment.error}</p>
            <form id="confirm-totp-form" phx-submit="confirm_totp" class="account-form">
              <label class="auth-field">
                <span>2. Confirm the code</span>
                <input
                  type="text"
                  name="code"
                  inputmode="numeric"
                  autocomplete="one-time-code"
                  spellcheck="false"
                  class="totp-code"
                  required
                />
              </label>
              <button type="submit" class="admin-button button-primary">
                Enable two-factor authentication
              </button>
            </form>
          <% true -> %>
            <p class="account-value">TOTP is not enabled.</p>
            <p class="auth-note">
              Password sign-in requires two-factor authentication; OAuth and passkey sign-ins may opt in.
            </p>
            <button class="admin-button button-primary" phx-click="start_totp">
              Set up two-factor authentication
            </button>
        <% end %>

        <div :if={@recovery_codes} class="recovery-panel">
          <h3>Save your recovery codes</h3>
          <p class="auth-note">Each code works once and will not be shown again.</p>
          <ul class="recovery-grid" aria-label="Recovery codes">
            <li :for={code <- @recovery_codes}><code>{code}</code></li>
          </ul>
        </div>
      </section>

      <section class="account-card">
        <h2>Security keys and passkeys</h2>
        <p :if={Config.enabled?()} class="account-value">
          <a class="button-link" href="/account/security">Manage security keys and passkeys</a>
        </p>
        <p :if={!Config.enabled?()} class="auth-note">
          Passkeys are disabled on this deployment.
        </p>
        <p class="account-value"><a class="button-link" href="/auth/tokens/new">Create a daemon token</a></p>
      </section>

      <section class="account-card">
        <h2>Sessions</h2>
        <p class="account-value">Signed in as {to_string(@current_user.email)}.</p>
        <button class="admin-button button-warning" phx-click="sign_out_everywhere">
          Sign out of every session
        </button>
      </section>
    </main>
    """
  end

  defp with_sudo(socket, fun) do
    if UserAuth.sudo_mode?(socket.assigns.current_session) do
      fun.(socket, socket.assigns.current_user)
    else
      {:noreply,
       socket
       |> put_flash(:error, "Re-authenticate to continue.")
       |> push_navigate(to: "/sign-in?sudo=1&return_to=/account")}
    end
  end

  defp refresh_account(socket) do
    user = socket.assigns.current_user

    assign_async(socket, [:recovery_count], fn ->
      {:ok, %{recovery_count: TOTP.count_unused(user)}}
    end)
  end

  defp put_enrollment_error(socket, user, message) do
    socket
    |> assign(:current_user, user)
    |> assign(:enrollment, %{
      secret: nil,
      qr_data_uri: nil,
      error: message
    })
    |> then(fn socket ->
      case TOTP.begin_enrollment(user) do
        {:ok, _user, secret} ->
          assign(socket, :enrollment, %{
            secret: TOTP.format_secret(secret),
            qr_data_uri: TOTP.qr_data_uri(user, secret),
            error: message
          })

        :error ->
          socket
      end
    end)
  end

  defp password_error(:too_short), do: "Use at least #{LocalAuth.min_length()} characters."
  defp password_error(:too_long), do: "Use at most #{LocalAuth.max_length()} characters."
  defp password_error(:mismatch), do: "The passwords do not match."
  defp password_error(:blank), do: "Enter a password."
  defp password_error(_error), do: "Could not update the password."

  defp recovery_count_label(1), do: "One recovery code remaining."
  defp recovery_count_label(count), do: "#{count} recovery codes remaining."
end
