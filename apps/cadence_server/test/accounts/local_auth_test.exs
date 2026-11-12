defmodule Cadence.Server.Accounts.LocalAuthTest do
  use ExUnit.Case, async: false

  alias Cadence.Server.Accounts.LocalAuth
  alias Cadence.Server.Accounts.User

  @password "correct horse battery staple"

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Cadence.Server.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "creates a local account with an Argon2id hash and normalized email" do
    assert {:ok, %User{} = user} =
             LocalAuth.create_user(%{
               email: "  Person@Example.COM ",
               name: "  Person  ",
               password: @password
             })

    assert to_string(user.email) == "person@example.com"
    assert user.name == "Person"
    assert String.starts_with?(user.hashed_password, "$argon2id$")
    assert user.confirmed_at
  end

  test "rejects a password below the configured minimum" do
    assert {:error, :too_short} =
             LocalAuth.create_user(%{email: "short@example.com", password: "short"})
  end

  test "rejects a password above the maximum" do
    assert {:error, :too_long} =
             LocalAuth.create_user(%{
               email: "long@example.com",
               password: String.duplicate("a", 73)
             })
  end

  test "rejects a blank password and a mismatched confirmation" do
    assert {:error, :blank} =
             LocalAuth.create_user(%{email: "blank@example.com", password: ""})

    assert {:error, :mismatch} =
             LocalAuth.create_user(%{
               email: "mismatch@example.com",
               password: @password,
               password_confirmation: "different password"
             })
  end

  test "requires an email" do
    assert {:error, :missing_email} =
             LocalAuth.create_user(%{email: "  ", password: @password})

    assert {:error, :invalid_email} =
             LocalAuth.create_user(%{email: "not-an-email", password: @password})
  end

  test "the unique email identity rejects a duplicate" do
    assert {:ok, _user} = LocalAuth.create_user(%{email: "dup@example.com", password: @password})

    assert {:error, error} =
             LocalAuth.create_user(%{email: "DUP@example.com", password: @password})

    assert Exception.message(error) =~ "already been taken"
  end

  test "verifies a correct password and rejects a wrong, unknown, or blank one" do
    assert {:ok, user} =
             LocalAuth.create_user(%{email: "verify@example.com", password: @password})

    assert LocalAuth.get_user_by_email_and_password("VERIFY@example.com", @password).id == user.id
    refute LocalAuth.get_user_by_email_and_password("verify@example.com", "wrong password")
    refute LocalAuth.get_user_by_email_and_password("nobody@example.com", @password)
    refute LocalAuth.get_user_by_email_and_password("verify@example.com", "")
  end

  test "a legacy bcrypt hash never authenticates but is still handled" do
    hash = "$2b$12$" <> String.duplicate("a", 53)

    assert {:ok, user} =
             User
             |> Ash.Changeset.for_create(:create, %{
               email: "legacy@example.com",
               hashed_password: hash
             })
             |> Ash.create(domain: Cadence.Server.Accounts)

    refute LocalAuth.valid_password?(user, @password)
    refute LocalAuth.get_user_by_email_and_password("legacy@example.com", @password)
  end

  test "a corrupted Argon2 hash fails closed" do
    assert {:ok, user} =
             User
             |> Ash.Changeset.for_create(:create, %{
               email: "corrupt@example.com",
               hashed_password: "$argon2id$not-a-valid-hash"
             })
             |> Ash.create(domain: Cadence.Server.Accounts)

    refute LocalAuth.valid_password?(user, @password)
  end

  test "set_password replaces the hash and invalidates the old password" do
    assert {:ok, user} =
             LocalAuth.create_user(%{email: "change@example.com", password: @password})

    assert {:ok, updated} = LocalAuth.set_password(user, "an entirely different password")
    assert updated.hashed_password != user.hashed_password

    refute LocalAuth.get_user_by_email_and_password("change@example.com", @password)

    assert LocalAuth.get_user_by_email_and_password(
             "change@example.com",
             "an entirely different password"
           )
  end

  test "set_password enforces the same policy" do
    assert {:ok, user} =
             LocalAuth.create_user(%{email: "policy@example.com", password: @password})

    assert {:error, :too_short} = LocalAuth.set_password(user, "short")
  end

  test "min_length falls back to 12 for a junk configuration" do
    original = Application.get_env(:cadence_server, :auth_password_min_length)
    Application.put_env(:cadence_server, :auth_password_min_length, 0)

    on_exit(fn ->
      Application.put_env(:cadence_server, :auth_password_min_length, original)
    end)

    assert LocalAuth.min_length() == 12
  end
end
