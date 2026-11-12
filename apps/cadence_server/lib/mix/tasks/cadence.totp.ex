defmodule Mix.Tasks.Cadence.Totp do
  @moduledoc """
  Prints the current TOTP code for an account (operator/demo helper).

      mix cadence.totp --email owner@demo.local

  This is intentionally an operator tool: it decrypts the stored secret using
  the server's `CAD_TOTP_KEY` / `CAD_SECRET_KEY_BASE`. It is useful for the
  seeded demo accounts and for recovering access when the authenticator device
  is temporarily unavailable but the operator still has shell access.

  A code shown here is not marked as used; the normal single-use rule still
  applies when it is submitted.
  """

  use Mix.Task

  @shortdoc "Prints the current TOTP code for an account"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args, strict: [email: :string])

    if invalid != [], do: Mix.raise("Unknown options: #{inspect(invalid)}")
    email = opts[:email] || Mix.raise("--email is required.")

    Mix.Task.run("app.config")

    # Never bind the HTTP port: this task is run inside an already-running
    # container with `docker compose exec`.
    endpoint_config = Application.get_env(:cadence_server, Cadence.ServerWeb.Endpoint, [])

    Application.put_env(
      :cadence_server,
      Cadence.ServerWeb.Endpoint,
      Keyword.put(endpoint_config, :server, false)
    )

    {:ok, _started} = Application.ensure_all_started(:cadence_server)

    alias Cadence.Server.Accounts.LocalAuth
    alias Cadence.Server.Accounts.TOTP

    user =
      case LocalAuth.get_by_email(email) do
        {:ok, %{} = user} -> user
        {:ok, nil} -> Mix.raise("No account exists for #{email}.")
        {:error, error} -> Mix.raise("Could not read accounts: #{inspect(error)}")
      end

    case TOTP.get_secret(user) do
      {:ok, secret} ->
        code = NimbleTOTP.verification_code(secret)
        remaining = 30 - rem(System.os_time(:second), 30)

        Mix.shell().info("TOTP code for #{user.email}: #{code}")
        Mix.shell().info("Valid for about #{remaining}s.")

        if recent_use?(user) do
          Mix.shell().info(
            "This code was already used in the current period and will be rejected; " <>
              "wait for the next code."
          )
        end

      :error ->
        Mix.raise("TOTP is not enrolled for #{user.email}.")
    end
  end

  defp recent_use?(%{totp_last_used_at: %DateTime{} = used_at}) do
    DateTime.diff(DateTime.utc_now(), used_at, :second) < 30
  end

  defp recent_use?(_user), do: false
end
