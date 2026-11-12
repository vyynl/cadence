defmodule Cadence.ServerWeb.SignInLive do
  @moduledoc """
  Cadence-owned sign-in page (plan §7.6, approval record).

  Replaces the generic `AshAuthentication.Phoenix.SignInLive` rendering while
  keeping the same `sign_in_route/1` session and on-mount behaviour, so the
  existing GitHub/Google OAuth and compile-gated demo-password strategies keep
  working unchanged.

  The passkey option is a plain link to `/auth/passkeys/sign-in`, a controller
  route that can write the session cookie on the request that completes the
  ceremony. The link is rendered only when `CAD_WEBAUTHN_ENABLED=true`.

  The mount/render shape mirrors the upstream MIT-licensed
  `AshAuthentication.Phoenix.SignInLive`.
  """

  use AshAuthentication.Phoenix.Web, :live_view

  alias AshAuthentication.Phoenix.Components
  alias Cadence.Server.Passkeys.Config
  alias Phoenix.LiveView.{Rendered, Socket}

  @default_overrides [AshAuthentication.Phoenix.Overrides.Default]

  @doc false
  @impl true
  def mount(_params, session, socket) do
    overrides = Map.get(session, "overrides", @default_overrides)

    socket =
      socket
      |> assign(overrides: overrides)
      |> assign_new(:otp_app, fn -> nil end)
      |> assign(:path, session["path"] || "/")
      |> assign(:reset_path, session["reset_path"])
      |> assign(:register_path, session["register_path"])
      |> assign(:current_tenant, session["tenant"])
      |> assign(:resources, session["resources"])
      |> assign(:context, session["context"] || %{})
      |> assign(:auth_routes_prefix, session["auth_routes_prefix"])
      |> assign(:gettext_fn, session["gettext_fn"])
      |> assign(:passkeys_enabled?, Config.enabled?())

    {:ok, socket}
  end

  @doc false
  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @doc false
  @impl true
  @spec render(Socket.assigns()) :: Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="sign-in-page">
      <section :if={@passkeys_enabled?} class="passkey-callout" aria-labelledby="passkey-heading">
        <p class="eyebrow">Security key or passkey</p>
        <h1 id="passkey-heading">Sign in to Cadence</h1>
        <a class="admin-button button-primary" href="/auth/passkeys/sign-in">
          Sign in with a security key or passkey
        </a>
        <p class="note">
          Plug in your security key and touch it when it blinks, or use a passkey saved in this
          browser or password manager. Using your phone? Choose <strong>Use a phone</strong>
          in the browser prompt and scan the QR code with your camera.
        </p>
      </section>

      <section :if={!@passkeys_enabled?} class="sign-in-page-header">
        <h1>Sign in to Cadence</h1>
      </section>

      <div class="sign-in-methods">
        <.live_component
          module={Components.SignIn}
          otp_app={@otp_app}
          live_action={@live_action}
          path={@path}
          auth_routes_prefix={@auth_routes_prefix}
          resources={@resources}
          reset_path={@reset_path}
          register_path={@register_path}
          id="sign-in"
          overrides={@overrides}
          current_tenant={@current_tenant}
          context={@context}
          gettext_fn={@gettext_fn}
        />
      </div>
    </div>
    """
  end
end
