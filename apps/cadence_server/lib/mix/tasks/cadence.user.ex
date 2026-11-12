defmodule Mix.Tasks.Cadence.User do
  @moduledoc """
  Creates an operator account, resets its password, or resets its TOTP.

      mix cadence.user --email you@example.com --name "Your Name"
      mix cadence.user --email you@example.com --reset-password
      mix cadence.user --email you@example.com --reset-totp

  Cadence has no public registration. The password comes from
  `CAD_USER_PASSWORD` when set, otherwise it is prompted for. Passwords must be
  at least 12 characters. TOTP enrollment happens on the first password login
  and cannot be skipped for local accounts.

  `--reset-totp` clears the stored secret and all recovery codes; the password
  and existing sessions are left to the operator reset paths. This is the
  recovery route for a lost authenticator or a rotated `CAD_TOTP_KEY`.
  """

  use Mix.Task

  @shortdoc "Creates/resets a Cadence local account or its TOTP"

  @impl Mix.Task
  def run(args) do
    opts = parse_options(args)
    start_app()

    email = opts[:email] || prompt("Email: ")

    if not is_binary(email) or String.trim(email) == "" do
      Mix.raise("An email is required.")
    end

    if opts[:reset_totp] do
      reset_totp(email)
    else
      password = opts[:password] || System.get_env("CAD_USER_PASSWORD") || prompt_password()
      create_or_reset(opts, email, password)
    end
  end

  defp parse_options(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          email: :string,
          name: :string,
          password: :string,
          reset_password: :boolean,
          reset_totp: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("Unknown options: #{inspect(invalid)}")
    opts
  end

  defp start_app do
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
  end

  defp create_or_reset(opts, email, password) do
    alias Cadence.Server.Accounts.LocalAuth

    case LocalAuth.get_by_email(email) do
      {:ok, %{} = user} ->
        if opts[:reset_password] do
          reset_password(user, password)
        else
          Mix.raise(
            "An account already exists for #{email}. " <>
              "Use --reset-password to change its password, or --reset-totp to reset 2FA."
          )
        end

      {:ok, nil} ->
        create_user(email, opts[:name], password)

      {:error, error} ->
        Mix.raise("Could not read accounts: #{inspect(error)}")
    end
  end

  defp create_user(email, name, password) do
    alias Cadence.Server.Accounts.LocalAuth

    case LocalAuth.create_user(%{email: email, name: name, password: password}) do
      {:ok, user} ->
        Mix.shell().info("""
        Created Cadence account #{user.email}.

        Sign in with the password, then complete TOTP enrollment immediately.
        """)

      {:error, error} ->
        Mix.raise("Could not create account: #{inspect(error)}")
    end
  end

  defp reset_password(user, password) do
    alias Cadence.Server.Accounts.LocalAuth

    case LocalAuth.set_password(user, password) do
      {:ok, _user} ->
        Cadence.ServerWeb.UserAuth.revoke_all(user.id)

        Mix.shell().info("""
        Password updated for #{user.email}. All browser sessions were revoked.

        Sign in with the new password, then verify the TOTP code.
        """)

      {:error, error} ->
        Mix.raise("Could not update password: #{inspect(error)}")
    end
  end

  defp reset_totp(email) do
    alias Cadence.Server.Accounts.LocalAuth
    alias Cadence.Server.Accounts.TOTP

    case LocalAuth.get_by_email(email) do
      {:ok, nil} ->
        Mix.raise("No account exists for #{email}.")

      {:ok, user} ->
        case TOTP.disable(user) do
          {:ok, _user} ->
            Cadence.ServerWeb.UserAuth.revoke_all(user.id)

            Mix.shell().info("""
            TOTP reset for #{user.email}. All browser sessions were revoked.

            The stored secret and all recovery codes were deleted. Log in with
            the password and enroll the new authenticator.
            """)

          {:error, error} ->
            Mix.raise("Could not reset TOTP: #{inspect(error)}")
        end

      {:error, error} ->
        Mix.raise("Could not read accounts: #{inspect(error)}")
    end
  end

  defp prompt(message) do
    case Mix.shell().prompt(message) do
      :eof -> ""
      value -> String.trim(value)
    end
  end

  defp prompt_password do
    Mix.shell().info("Set CAD_USER_PASSWORD to avoid typing the password in the shell.")
    prompt("Password (min 12 chars): ")
  end
end
