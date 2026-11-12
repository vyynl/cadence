defmodule Cadence.Server.Accounts.TOTP do
  @moduledoc """
  TOTP enrollment, verification, and recovery codes (spec §7.4).

  The shared secret is encrypted at rest by
  `Cadence.Server.Security.SecretBox`. Enrollment is a compare-and-set so two
  tabs converge on one QR code; a confirmed secret is never overwritten.
  Verification is serialized on the user row and records the accepted time
  step, so a code cannot be replayed. Recovery codes are single-use hashes.
  """

  import Ecto.Query

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.RecoveryCode
  alias Cadence.Server.Accounts.User
  alias Cadence.Server.Repo
  alias Cadence.Server.Security.SecretBox

  @recovery_code_count 10
  @default_issuer "Cadence"

  @doc "Whether the user has completed TOTP enrollment."
  @spec enabled?(User.t()) :: boolean()
  def enabled?(%User{totp_confirmed_at: %DateTime{}}), do: true
  def enabled?(_user), do: false

  @doc "Returns the decrypted TOTP secret for a user, if one exists."
  @spec get_secret(User.t()) :: {:ok, binary()} | :error
  def get_secret(%User{totp_secret: nil}), do: :error

  def get_secret(%User{totp_secret: encrypted}) when is_binary(encrypted),
    do: SecretBox.decrypt(encrypted)

  def get_secret(_user), do: :error

  @doc """
  Starts (or resumes) enrollment of an unconfirmed secret and returns the
  plaintext secret for the QR code / manual entry.

  The first write only lands while `totp_secret IS NULL`. A caller that loses
  the race reads the winner's secret instead of writing its own. A stored
  secret that cannot be decrypted is healed only while enrollment is
  unconfirmed; a confirmed secret is never replaced.
  """
  @spec begin_enrollment(User.t()) :: {:ok, User.t(), binary()} | :error
  def begin_enrollment(%User{} = user) do
    secret = NimbleTOTP.secret()
    encrypted = SecretBox.encrypt(secret)
    now = DateTime.utc_now()

    if claim_unclaimed(user.id, encrypted, now) do
      case reload(user.id) do
        {:ok, updated} -> {:ok, updated, secret}
        _error -> :error
      end
    else
      resume_or_heal(user.id, secret, encrypted, now)
    end
  end

  @doc """
  Confirms enrollment with a valid code and returns the plaintext recovery
  codes. The codes are shown once and only their hashes are stored.
  """
  @spec confirm_enrollment(User.t(), term()) ::
          {:ok, User.t(), [String.t()]} | {:error, :not_started | :invalid_code | term()}
  def confirm_enrollment(%User{totp_secret: nil}, _code), do: {:error, :not_started}

  def confirm_enrollment(%User{} = user, code) when is_binary(code) do
    with {:ok, secret} <- get_secret(user),
         true <- NimbleTOTP.valid?(secret, code, since: user.totp_last_used_at) do
      now = now_seconds()

      tx(fn ->
        case lock_user(user.id) do
          {:ok, locked} ->
            case update_tx(locked, :confirm_totp, %{
                   totp_secret: locked.totp_secret,
                   totp_confirmed_at: now,
                   totp_last_used_at: now
                 }) do
              {:ok, updated, notifications} ->
                {{:ok, updated, replace_recovery_codes(locked.id)}, notifications}

              {:error, error} ->
                Repo.rollback(error)
            end

          :error ->
            Repo.rollback(:not_found)
        end
      end)
      |> case do
        {:ok, {:ok, updated, codes}} -> {:ok, updated, codes}
        {:ok, other} -> other
        {:error, error} -> {:error, error}
      end
    else
      _error -> {:error, :invalid_code}
    end
  end

  def confirm_enrollment(_user, _code), do: {:error, :invalid_code}

  @doc """
  Verifies a current TOTP code and records its time step.

  Returns `:ok` only when the code is valid and has not been used in the same
  period. The user row is locked for the duration so two concurrent requests
  cannot both accept the same code.
  """
  @spec verify(User.t(), term()) :: :ok | :error
  def verify(%User{} = user, code) when is_binary(code) do
    if enabled?(user) do
      tx(fn ->
        case lock_user(user.id) do
          {:ok, locked} ->
            with {:ok, secret} <- get_secret(locked),
                 true <- NimbleTOTP.valid?(secret, code, since: locked.totp_last_used_at),
                 {:ok, _updated, notifications} <-
                   update_tx(locked, :mark_totp_used, %{totp_last_used_at: now_seconds()}) do
              {:ok, notifications}
            else
              _error -> Repo.rollback(:invalid_code)
            end

          :error ->
            Repo.rollback(:not_found)
        end
      end)
      |> case do
        {:ok, _notifications} -> :ok
        _error -> :error
      end
    else
      :error
    end
  end

  def verify(_user, _code), do: :error

  @doc """
  Accepts either a current TOTP code or an unused recovery code.

  Returns `{:ok, :totp | :recovery}` or `:error`. The controller uses the
  recovery branch to tell the user to regenerate codes soon.
  """
  @spec verify_login(User.t(), term()) :: {:ok, :totp | :recovery} | :error
  def verify_login(%User{} = user, code) when is_binary(code) do
    case verify(user, code) do
      :ok ->
        {:ok, :totp}

      :error ->
        case consume_recovery_code(user, code) do
          {:ok, _user} -> {:ok, :recovery}
          :error -> :error
        end
    end
  end

  def verify_login(_user, _code), do: :error

  @doc """
  Consumes an unused recovery code. The check and the single-use marker are one
  atomic update, so two concurrent submissions cannot both succeed.
  """
  @spec consume_recovery_code(User.t(), term()) :: {:ok, User.t()} | :error
  def consume_recovery_code(%User{} = user, code) do
    {count, _rows} =
      Repo.update_all(
        from(rc in RecoveryCode,
          where:
            rc.user_id == ^user.id and rc.code_hash == ^hash_code(code) and is_nil(rc.used_at)
        ),
        set: [used_at: now_seconds()]
      )

    if count == 1, do: {:ok, user}, else: :error
  end

  @doc "Counts unused recovery codes."
  @spec count_unused(User.t() | String.t()) :: non_neg_integer()
  def count_unused(%User{id: id}), do: count_unused(id)

  def count_unused(user_id) when is_binary(user_id) do
    Repo.aggregate(
      from(rc in RecoveryCode, where: rc.user_id == ^user_id and is_nil(rc.used_at)),
      :count
    )
  end

  @doc "Deletes every existing recovery code and returns a fresh set (once)."
  @spec regenerate_recovery_codes(User.t()) :: {:ok, [String.t()]} | {:error, term()}
  def regenerate_recovery_codes(%User{id: id}) do
    Repo.transaction(fn -> replace_recovery_codes(id) end)
  end

  @doc "Disables TOTP and removes every recovery code."
  @spec disable(User.t()) :: {:ok, User.t()} | {:error, term()}
  def disable(%User{} = user) do
    tx(fn ->
      case update_tx(user, :clear_totp, %{
             totp_secret: nil,
             totp_confirmed_at: nil,
             totp_last_used_at: nil
           }) do
        {:ok, updated, notifications} ->
          Repo.delete_all(from(rc in RecoveryCode, where: rc.user_id == ^user.id))
          {updated, notifications}

        {:error, error} ->
          Repo.rollback(error)
      end
    end)
  end

  @doc "The otpauth URI encoded in the enrollment QR code."
  @spec otpauth_uri(User.t(), binary()) :: String.t()
  def otpauth_uri(%User{email: email}, secret) do
    NimbleTOTP.otpauth_uri("#{issuer()}:#{email}", secret, issuer: issuer())
  end

  @doc "The enrollment QR code as an SVG data URI, or `nil` on render failure."
  @spec qr_data_uri(User.t(), binary()) :: String.t() | nil
  def qr_data_uri(%User{} = user, secret) do
    # `QRCode.render/2` expects the *result* of `QRCode.create/2`, not the bare
    # struct; passing the struct silently returns it unchanged (qr_code 3.2).
    result = QRCode.create(otpauth_uri(user, secret), :medium)

    with {:ok, svg} <- QRCode.render(result, :svg) do
      "data:image/svg+xml;base64," <> Base.encode64(svg)
    else
      _error -> nil
    end
  end

  @doc "Formats a raw secret for manual entry (base32, grouped in fours)."
  @spec format_secret(binary()) :: String.t()
  def format_secret(secret) do
    secret
    |> Base.encode32(padding: false)
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &Enum.join/1)
  end

  @doc "Fixed-encoding recovery code generator (8 random bytes, base32)."
  @spec generate_recovery_code() :: String.t()
  def generate_recovery_code do
    :crypto.strong_rand_bytes(8)
    |> Base.encode32(case: :upper, padding: false)
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &Enum.join/1)
  end

  defp claim_unclaimed(id, encrypted, now) do
    {claimed, _rows} =
      Repo.update_all(
        from(u in "users", where: u.id == type(^id, :binary_id) and is_nil(u.totp_secret)),
        set: [
          totp_secret: encrypted,
          totp_confirmed_at: nil,
          totp_last_used_at: nil,
          updated_at: now
        ]
      )

    claimed == 1
  end

  defp resume_or_heal(id, secret, encrypted, now) do
    case reload(id) do
      {:ok, stored} ->
        case get_secret(stored) do
          {:ok, existing} -> {:ok, stored, existing}
          :error -> heal(stored, secret, encrypted, now)
        end

      _error ->
        :error
    end
  end

  defp heal(%User{totp_confirmed_at: nil, totp_secret: stored} = user, secret, encrypted, now)
       when is_binary(stored) do
    {claimed, _rows} =
      Repo.update_all(
        from(u in "users",
          where:
            u.id == type(^user.id, :binary_id) and u.totp_secret == ^stored and
              is_nil(u.totp_confirmed_at)
        ),
        set: [
          totp_secret: encrypted,
          totp_confirmed_at: nil,
          totp_last_used_at: nil,
          updated_at: now
        ]
      )

    case claimed do
      1 ->
        case reload(user.id) do
          {:ok, updated} -> {:ok, updated, secret}
          _error -> :error
        end

      0 ->
        resume_stored(user.id)
    end
  end

  defp heal(_user, _secret, _encrypted, _now), do: :error

  defp resume_stored(id) do
    with {:ok, stored} <- reload(id),
         {:ok, secret} <- get_secret(stored) do
      {:ok, stored, secret}
    else
      _error -> :error
    end
  end

  defp replace_recovery_codes(user_id) do
    Repo.delete_all(from(rc in RecoveryCode, where: rc.user_id == ^user_id))

    now = DateTime.utc_now()

    {codes, rows} =
      Enum.map_reduce(1..@recovery_code_count, [], fn _n, rows ->
        code = generate_recovery_code()

        row = %{
          id: Ecto.UUID.generate(),
          user_id: user_id,
          code_hash: hash_code(code),
          used_at: nil,
          inserted_at: now
        }

        {code, [row | rows]}
      end)

    Repo.insert_all(RecoveryCode, rows)
    codes
  end

  defp hash_code(code) do
    code
    |> normalize_code()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp normalize_code(code) do
    code
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]/, "")
  end

  defp lock_user(id) do
    case Repo.query("SELECT id FROM users WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(id)]) do
      {:ok, %{num_rows: 1}} ->
        case Ash.get(User, id, domain: Accounts) do
          {:ok, user} -> {:ok, user}
          _error -> :error
        end

      _other ->
        :error
    end
  end

  defp reload(id) do
    Ash.get(User, id, domain: Accounts)
  end

  defp update_tx(user, action, attrs) do
    user
    |> Ash.Changeset.for_update(action, attrs)
    |> Ash.update(domain: Accounts, return_notifications?: true)
  end

  # Ash cannot deliver notifications inside a transaction; collect them and
  # send them after commit so the transaction does not warn (or silently drop
  # a notifier added later).
  defp tx(fun) do
    case Repo.transaction(fun) do
      {:ok, {result, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, result}

      {:error, error} ->
        {:error, error}
    end
  end

  defp now_seconds, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp issuer do
    Application.get_env(:cadence_server, :auth_totp_issuer, @default_issuer)
  end
end
