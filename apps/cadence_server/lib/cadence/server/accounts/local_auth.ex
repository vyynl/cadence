defmodule Cadence.Server.Accounts.LocalAuth do
  @moduledoc """
  Local email/password authentication for operator-created Cadence accounts
  (spec §7.4).

  Accounts are never self-registered. An operator creates one with
  `mix cadence.user` (or `Cadence.Server.Release.create_user/2`), and the first
  password login forces TOTP enrollment.

  Passwords are Argon2id. Unknown accounts and accounts without a password run
  the dummy verification path, so the response time does not reveal whether an
  email exists.
  """

  require Ash.Query

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.User

  @default_min_length 12
  @max_length 72

  @doc "The configured minimum password length."
  @spec min_length() :: pos_integer()
  def min_length do
    case Application.get_env(:cadence_server, :auth_password_min_length, @default_min_length) do
      length when is_integer(length) and length > 0 -> length
      _other -> @default_min_length
    end
  end

  @doc "The maximum accepted password length."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Finds a user by email (case-insensitive; the stored field is a `ci_string`).
  """
  @spec get_by_email(term()) :: {:ok, User.t()} | {:error, term()} | {:ok, nil}
  def get_by_email(email) when is_binary(email) do
    normalized = normalize_email(email)

    User
    |> Ash.Query.filter(email == ^normalized)
    |> Ash.read_one(domain: Accounts)
  end

  def get_by_email(_email), do: {:ok, nil}

  @doc """
  Returns the user when the password matches, otherwise `nil`.

  Always pays a password-hash cost: a missing user or a user without a
  password runs `Argon2.no_user_verify/0`.
  """
  @spec get_user_by_email_and_password(term(), term()) :: User.t() | nil
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    case get_by_email(email) do
      {:ok, %User{} = user} -> if valid_password?(user, password), do: user
      _other -> dummy_nil()
    end
  end

  def get_user_by_email_and_password(_email, _password), do: dummy_nil()

  @doc "Verifies a password against a stored Argon2 hash."
  @spec valid_password?(User.t() | nil, term()) :: boolean()
  def valid_password?(%User{hashed_password: hash}, password)
      when is_binary(hash) and is_binary(password) and byte_size(password) > 0 do
    if argon2_hash?(hash) do
      try do
        Argon2.verify_pass(password, hash)
      rescue
        # A truncated/corrupted hash must fail closed, not 500 the sign-in page.
        _error -> dummy_verify()
      end
    else
      # Legacy bcrypt (demo-only) or an unreadable hash: never authenticate,
      # but still pay a hash cost so the failure keeps the same timing shape.
      dummy_verify()
    end
  end

  def valid_password?(_user, _password), do: dummy_verify()

  @doc "Hashes a password with Argon2id and a random salt."
  @spec hash_password(binary()) :: String.t()
  def hash_password(password) when is_binary(password), do: Argon2.hash_pwd_salt(password)

  @doc """
  Validates the password policy.

  Returns `:ok` or `{:error, :blank | :too_short | :too_long | :mismatch}`.
  """
  @spec validate_password(term(), term()) :: :ok | {:error, atom()}
  def validate_password(password, confirmation \\ nil) do
    cond do
      not is_binary(password) or password == "" -> {:error, :blank}
      byte_size(password) < min_length() -> {:error, :too_short}
      byte_size(password) > max_length() -> {:error, :too_long}
      is_binary(confirmation) and confirmation != password -> {:error, :mismatch}
      true -> :ok
    end
  end

  @doc """
  Creates a local account from `%{email, name, password, password_confirmation}`
  (string or atom keys). There is no public registration route.
  """
  @spec create_user(map()) :: {:ok, User.t()} | {:error, term()}
  def create_user(attrs) when is_map(attrs) do
    email = get_attr(attrs, :email)
    name = get_attr(attrs, :name)
    password = get_attr(attrs, :password)
    confirmation = get_attr(attrs, :password_confirmation)

    with :ok <- require_email(email),
         :ok <- validate_password(password, confirmation) do
      params = %{
        email: normalize_email(email),
        name: normalize_name(name),
        hashed_password: hash_password(password)
      }

      User
      |> Ash.Changeset.for_create(:create, params)
      |> Ash.create(domain: Accounts)
    end
  end

  @doc """
  Replaces a user's password after validating the policy.

  Session revocation is the caller's job: after a successful change, every
  `user_sessions` row for the user must be deleted.
  """
  @spec set_password(User.t(), term(), term()) :: {:ok, User.t()} | {:error, term()}
  def set_password(%User{} = user, password, confirmation \\ nil) do
    with :ok <- validate_password(password, confirmation) do
      user
      |> Ash.Changeset.for_update(:set_password, %{hashed_password: hash_password(password)})
      |> Ash.update(domain: Accounts)
    end
  end

  @doc "Case-folds and trims an email for storage and rate-limit keys."
  @spec normalize_email(term()) :: String.t()
  def normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  def normalize_email(_email), do: ""

  defp normalize_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_name(_name), do: nil

  defp require_email(email) when is_binary(email) do
    email = String.trim(email)

    cond do
      email == "" -> {:error, :missing_email}
      byte_size(email) > 160 -> {:error, :invalid_email}
      not Regex.match?(~r/^[^@,;\s]+@[^@,;\s]+$/, email) -> {:error, :invalid_email}
      true -> :ok
    end
  end

  defp require_email(_email), do: {:error, :missing_email}

  defp argon2_hash?(hash), do: String.starts_with?(hash, "$argon2")

  defp dummy_verify do
    Argon2.no_user_verify()
    false
  end

  defp dummy_nil do
    Argon2.no_user_verify()
    nil
  end

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
