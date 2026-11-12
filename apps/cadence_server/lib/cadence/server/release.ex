defmodule Cadence.Server.Release do
  @moduledoc """
  One-shot release tasks for the production server artifact (spec §12.7,
  §12.8).

  Migrations are deliberately **not** run from the container entrypoint. The
  reference compose stack runs this module as a one-shot `migrate` service and
  starts the endpoint only after it succeeds:

      docker compose -f docker-compose.prod.yml up -d --build

  The same command can be run by hand:

      bin/cadence eval "Cadence.Server.Release.migrate()"
  """

  @app :cadence_server

  @doc """
  Applies every pending migration for the repos configured under
  `:cadence_server, :ecto_repos`.

  Safe to run repeatedly: `Ecto.Migrator` skips versions that are already
  recorded in `schema_migrations`.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    Enum.each(repos(), fn repo ->
      {:ok, _repo, _started_apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end)
  end

  @doc "The repos this application migrates."
  @spec repos() :: [module()]
  def repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  @doc "The migration directory `Ecto` uses for `repo`."
  @spec migrations_path(module()) :: String.t()
  def migrations_path(repo) do
    Ecto.Migrator.migrations_path(repo)
  end

  @doc """
  Creates the first operator account from `CAD_ADMIN_*` on first boot.

  The reference compose stack runs this module as a one-shot `bootstrap`
  service. When `CAD_ADMIN_PASSWORD` is unset the call is a no-op, so removing
  it after the first sign-in is safe and an operator can still create accounts
  by hand. When the account already exists the call is also a no-op, which
  makes every `up` safe.

      bin/cadence eval 'Cadence.Server.Release.bootstrap_admin()'
  """
  @spec bootstrap_admin() :: :ok
  def bootstrap_admin do
    case admin_config(System.get_env()) do
      :skip ->
        IO.puts("CAD_ADMIN_EMAIL/CAD_ADMIN_PASSWORD not set; skipping first-account bootstrap.")

      {:ok, %{email: email, name: name, password: password}} ->
        ensure_user(email, name, password)

      {:error, message} ->
        raise message
    end

    :ok
  end

  @doc """
  Parses the first-account bootstrap environment.

  The password is the trigger: a blank `CAD_ADMIN_PASSWORD` is always `:skip`
  (so removing it after the first sign-in is safe). A password without an email
  is a readable `{:error, message}`.
  """
  @spec admin_config(map()) :: :skip | {:ok, map()} | {:error, String.t()}
  def admin_config(env) when is_map(env) do
    email = env |> Map.get("CAD_ADMIN_EMAIL") |> blank_to_nil()
    password = env |> Map.get("CAD_ADMIN_PASSWORD") |> blank_to_nil()
    name = env |> Map.get("CAD_ADMIN_NAME") |> blank_to_nil()

    cond do
      is_nil(password) ->
        :skip

      is_nil(email) ->
        {:error, "CAD_ADMIN_EMAIL is required when CAD_ADMIN_PASSWORD is set."}

      true ->
        {:ok, %{email: email, name: name, password: password}}
    end
  end

  @doc """
  Creates `email` when it does not exist yet; otherwise leaves it untouched.

  This is the idempotent form used by the compose `bootstrap` service, so a
  normal `docker compose up` cannot fail just because the account was already
  created.
  """
  @spec ensure_user(String.t(), String.t() | nil, String.t()) :: :ok
  def ensure_user(email, name, password) do
    with_repo(fn ->
      case Cadence.Server.Accounts.LocalAuth.get_by_email(email) do
        {:ok, nil} ->
          case Cadence.Server.Accounts.LocalAuth.create_user(%{
                 email: email,
                 name: name,
                 password: password
               }) do
            {:ok, user} -> IO.puts("Created Cadence account #{user.email}.")
            {:error, error} -> raise "Could not create account: #{inspect(error)}"
          end

        {:ok, user} ->
          IO.puts("Cadence account #{user.email} already exists; bootstrap unchanged.")

        {:error, error} ->
          raise "Could not read accounts: #{inspect(error)}"
      end
    end)

    :ok
  end

  @doc """
  Creates a local account from a release shell.

      bin/cadence eval 'Cadence.Server.Release.create_user("you@example.com", "You", "a long password")'

  Raises with a readable message when the account already exists or the
  password fails the policy. There is no public registration route.
  """
  @spec create_user(String.t(), String.t() | nil, String.t()) :: :ok
  def create_user(email, name, password) do
    do_create_user(email, name, password)
  end

  @doc """
  Creates a local account without a display name from a release shell.
  """
  @spec create_user(String.t(), String.t()) :: :ok
  def create_user(email, password) do
    do_create_user(email, nil, password)
  end

  defp do_create_user(email, name, password) do
    with_repo(fn ->
      case Cadence.Server.Accounts.LocalAuth.create_user(%{
             email: email,
             name: name,
             password: password
           }) do
        {:ok, user} -> IO.puts("Created Cadence account #{user.email}.")
        {:error, error} -> raise "Could not create account: #{inspect(error)}"
      end
    end)

    :ok
  end

  @doc """
  Resets a local account password from a release shell.

      bin/cadence eval 'Cadence.Server.Release.reset_password("you@example.com", "a long password")'
  """
  @spec reset_password(String.t(), String.t()) :: :ok
  def reset_password(email, password) do
    with_repo(fn ->
      with {:ok, user} when not is_nil(user) <-
             Cadence.Server.Accounts.LocalAuth.get_by_email(email),
           {:ok, _user} <- Cadence.Server.Accounts.LocalAuth.set_password(user, password) do
        Cadence.ServerWeb.UserAuth.revoke_all(user.id)
        IO.puts("Password updated for #{user.email}; all browser sessions were revoked.")
      else
        {:ok, nil} -> raise "No account exists for #{email}."
        {:error, error} -> raise "Could not update password: #{inspect(error)}"
      end
    end)

    :ok
  end

  @doc """
  Clears an account's TOTP secret and recovery codes from a release shell.

      bin/cadence eval 'Cadence.Server.Release.reset_totp("you@example.com")'
  """
  @spec reset_totp(String.t()) :: :ok
  def reset_totp(email) do
    with_repo(fn ->
      with {:ok, user} when not is_nil(user) <-
             Cadence.Server.Accounts.LocalAuth.get_by_email(email),
           {:ok, _user} <- Cadence.Server.Accounts.TOTP.disable(user) do
        Cadence.ServerWeb.UserAuth.revoke_all(user.id)
        IO.puts("TOTP reset for #{user.email}; all browser sessions were revoked.")
      else
        {:ok, nil} -> raise "No account exists for #{email}."
        {:error, error} -> raise "Could not reset TOTP: #{inspect(error)}"
      end
    end)

    :ok
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp with_repo(fun) do
    load_app()

    case Ecto.Migrator.with_repo(Cadence.Server.Repo, fn _repo -> fun.() end) do
      {:ok, _repo, result} -> result
      {:error, error} -> raise "Could not start the server repo: #{inspect(error)}"
    end
  end

  defp load_app do
    # Returns {:error, {:already_loaded, _}} when the release boot script has
    # already loaded it, which is fine.
    Application.load(@app)
    :ok
  end
end
