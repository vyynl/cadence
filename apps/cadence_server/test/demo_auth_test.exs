defmodule Cadence.Server.DemoAuthTest do
  @moduledoc """
  The compile-gated demo password strategy (spec §7.4).

  These assertions run against the test build, where `config/test.exs` sets
  `demo_auth: true`. The production direction (strategy absent) is covered by
  the `MIX_ENV=prod mix compile` verification gate and the `runtime.exs` guard.
  """

  use ExUnit.Case, async: false

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.User

  @password "cadence-demo"

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Cadence.Server.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "the demo password strategy is compiled in with registration disabled" do
    assert {:ok, strategy} = AshAuthentication.Info.strategy(User, :demo)
    refute strategy.registration_enabled?
    assert strategy.sign_in_enabled?
  end

  test "registration has no action and therefore no route" do
    refute Ash.Resource.Info.action(User, :register_with_demo)
  end

  test "a seeded user signs in with the demo password" do
    user = create_user("owner@demo.local", "Demo Owner")

    assert {:ok, signed_in} =
             User
             |> Ash.Query.for_read(:sign_in_with_demo, %{
               email: user.email,
               password: @password
             })
             |> Ash.read_one(domain: Accounts)

    assert signed_in.id == user.id
  end

  test "a wrong password is refused" do
    create_user("wrong@demo.local", "Wrong Password")

    assert {:error, _reason} =
             User
             |> Ash.Query.for_read(:sign_in_with_demo, %{
               email: "wrong@demo.local",
               password: "not-the-password"
             })
             |> Ash.read_one(domain: Accounts)
  end

  test "an unknown email is refused" do
    assert {:error, _reason} =
             User
             |> Ash.Query.for_read(:sign_in_with_demo, %{
               email: "nobody@demo.local",
               password: @password
             })
             |> Ash.read_one(domain: Accounts)
  end

  test "the internal create action stores a hashed password" do
    user = create_user("hashed@demo.local", "Hashed")

    assert is_binary(user.hashed_password)
    refute user.hashed_password == @password
    assert Bcrypt.verify_pass(@password, user.hashed_password)
  end

  test "the internal create action rejects a non-bcrypt password value" do
    assert {:error, _reason} =
             User
             |> Ash.Changeset.for_create(:create, %{
               email: "plaintext@demo.local",
               name: "Plaintext",
               hashed_password: "not-a-hash"
             })
             |> Ash.create(domain: Accounts)

    assert {:error, _reason} =
             User
             |> Ash.Changeset.for_create(:create, %{email: "nohash@demo.local", name: "No Hash"})
             |> Ash.create(domain: Accounts)
  end

  defp create_user(email, name) do
    {:ok, user} =
      Accounts.User
      |> Ash.Changeset.for_create(:create, %{
        email: email,
        name: name,
        hashed_password: Bcrypt.hash_pwd_salt(@password)
      })
      |> Ash.create(domain: Accounts)

    user
  end
end
