defmodule Cadence.Server.AccountsTest do
  use ExUnit.Case, async: false

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.{ApiKey, User}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Cadence.Server.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "creates a hashed API key and exposes the plaintext once" do
    user = Ash.Seed.seed!(User, %{email: "owner@example.com", name: "Owner"})

    assert {:ok, api_key} = Accounts.create_api_key(user, "laptop")
    plaintext = api_key.__metadata__.plaintext_api_key

    assert is_binary(plaintext)
    assert String.starts_with?(plaintext, "cad_")
    assert api_key.api_key_hash != plaintext
    refute Map.has_key?(api_key, :plaintext_api_key)

    loaded = Ash.get!(ApiKey, api_key.id)
    assert loaded.api_key_hash == api_key.api_key_hash
    refute loaded.api_key_hash == plaintext
  end

  test "signs in with a valid API key" do
    user = Ash.Seed.seed!(User, %{email: "signin@example.com"})
    assert {:ok, api_key} = Accounts.create_api_key(user, "daemon")
    plaintext = api_key.__metadata__.plaintext_api_key

    assert {:ok, signed_in} = sign_in(plaintext)
    assert signed_in.id == user.id
  end

  test "rejects an unknown API key" do
    assert {:ok, nil} = sign_in("cad_not_a_real_key")
  end

  test "rejects a revoked API key" do
    user = Ash.Seed.seed!(User, %{email: "revoked@example.com"})
    assert {:ok, api_key} = Accounts.create_api_key(user, "daemon")
    plaintext = api_key.__metadata__.plaintext_api_key

    assert :ok = Ash.destroy(api_key)
    assert {:ok, nil} = sign_in(plaintext)
  end

  test "rejects an expired API key" do
    user = Ash.Seed.seed!(User, %{email: "expired@example.com"})

    expires_at = DateTime.add(DateTime.utc_now(), -60, :second)

    assert {:ok, api_key} =
             Ash.create(
               ApiKey,
               %{user_id: user.id, name: "old", expires_at: expires_at},
               action: :create
             )

    plaintext = api_key.__metadata__.plaintext_api_key
    assert {:ok, nil} = sign_in(plaintext)
  end

  test "OAuth registration creates a user and an identity" do
    assert {:ok, user} =
             Ash.create(
               User,
               %{
                 user_info: %{
                   "sub" => "github-123",
                   "email" => "oauth@example.com",
                   "name" => "OAuth User"
                 },
                 oauth_tokens: %{"access_token" => "token"}
               },
               action: :register_with_github
             )

    assert to_string(user.email) == "oauth@example.com"
    assert user.name == "OAuth User"
    assert user.confirmed_at
  end

  defp sign_in(api_key) do
    User
    |> Ash.Query.for_read(:sign_in_with_api_key, %{api_key: api_key})
    |> Ash.read_one(domain: Cadence.Server.Accounts)
  end
end
