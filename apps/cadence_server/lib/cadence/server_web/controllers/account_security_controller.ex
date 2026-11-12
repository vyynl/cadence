defmodule Cadence.ServerWeb.AccountSecurityController do
  @moduledoc """
  Authenticated security-key / passkey management (plan §7.7).

  The page lists every credential owned by the signed-in user, accepts a label
  rename, and removes a key after a second confirmation step. Removal is
  scoped by `user_id` inside `Cadence.Server.Passkeys`, so a made-up row id can
  never touch another account. The last key is removable by design: OAuth
  remains the recovery path (plan §7.7, approval record).
  """

  use Cadence.ServerWeb, :controller

  alias Cadence.Server.Passkeys
  alias Cadence.Server.Passkeys.Config
  alias Cadence.ServerWeb.PasskeyHelpers

  def index(conn, _params) do
    PasskeyHelpers.with_user(conn, fn conn, user ->
      case Passkeys.list(user) do
        {:ok, credentials} ->
          render_index(conn, credentials)

        {:error, _reason} ->
          conn
          |> put_status(:internal_server_error)
          |> put_view(Cadence.ServerWeb.ErrorHTML)
          |> render("500.html")
      end
    end)
  end

  def rename(conn, %{"id" => row_id, "label" => label}) do
    PasskeyHelpers.with_user(conn, fn conn, user ->
      case Passkeys.rename_by_id(user, row_id, normalize_label(label)) do
        {:ok, credential} ->
          conn
          |> put_flash(:info, "Renamed this key to “#{credential.label}”.")
          |> redirect(to: "/account/security")

        {:error, :not_found} ->
          conn
          |> put_flash(:error, "That security key could not be found.")
          |> redirect(to: "/account/security")

        {:error, reason} ->
          conn
          |> put_flash(:error, rename_error(reason))
          |> redirect(to: "/account/security")
      end
    end)
  end

  def rename(conn, _params), do: rename(conn, %{"id" => "", "label" => ""})

  def delete(conn, %{"id" => row_id}) do
    PasskeyHelpers.with_user(conn, fn conn, user ->
      case Passkeys.delete_by_id(user, row_id) do
        :ok ->
          conn
          |> put_flash(:info, "Security key removed.")
          |> redirect(to: "/account/security")

        {:error, :not_found} ->
          conn
          |> put_flash(:error, "That security key could not be found.")
          |> redirect(to: "/account/security")

        {:error, _reason} ->
          conn
          |> put_flash(:error, "That security key could not be removed. Try again.")
          |> redirect(to: "/account/security")
      end
    end)
  end

  def delete(conn, _params), do: delete(conn, %{"id" => ""})

  defp render_index(conn, credentials) do
    render(conn, :index,
      page_title: "Account security",
      page_description: "Manage the security keys and passkeys that sign in to your account.",
      credentials: credentials,
      max_credentials: Config.get().max_credentials,
      csrf: Plug.CSRFProtection.get_csrf_token()
    )
  end

  defp normalize_label(label) when is_binary(label), do: String.trim(label)
  defp normalize_label(_label), do: ""

  defp rename_error(:invalid_label), do: "Enter a name between 1 and 60 characters."
  defp rename_error(_reason), do: "That security key could not be renamed. Try again."
end
