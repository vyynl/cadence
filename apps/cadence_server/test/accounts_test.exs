defmodule Cadence.Server.AccountsTest do
  # Serial on purpose: the query-counter tests attach a global `:telemetry`
  # handler, so this module must not run concurrently with other DB tests.
  # Do not flip this to `async: true`.
  use ExUnit.Case, async: false

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.{ApiKey, User}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Cadence.Server.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # Attached for every test so `user_query_count() == 0` means "the handler was
    # live and saw nothing", not "nothing was observed".
    attach_user_query_counter()
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

  test "authenticates API keys outside the HTTP plug" do
    user = Ash.Seed.seed!(User, %{email: "socket-auth@example.com"})
    assert {:ok, api_key} = Accounts.create_api_key(user, "socket")
    plaintext = api_key.__metadata__.plaintext_api_key

    assert {:ok, authenticated} = Accounts.authenticate_api_key(plaintext)
    assert authenticated.id == user.id

    assert {:error, :invalid_api_key} = Accounts.authenticate_api_key("cad_not_a_real_key")
    assert {:error, :invalid_api_key} = Accounts.authenticate_api_key(nil)
  end

  describe "users_by_ids/1" do
    test "returns a map keyed by user id for every existing user" do
      users =
        for i <- 1..3 do
          Ash.Seed.seed!(User, %{email: "batch-#{i}@example.com", name: "Batch #{i}"})
        end

      loaded = Accounts.users_by_ids(Enum.map(users, & &1.id))

      assert map_size(loaded) == 3
      assert Enum.sort(Map.keys(loaded)) == Enum.sort(Enum.map(users, & &1.id))

      for user <- users do
        assert loaded[user.id].email == user.email
        assert loaded[user.id].name == user.name
      end
    end

    test "omits unknown and malformed ids instead of raising" do
      [known_a, known_b] =
        for i <- 1..2 do
          Ash.Seed.seed!(User, %{email: "known-#{i}@example.com", name: "Known #{i}"})
        end

      loaded =
        Accounts.users_by_ids([
          known_a.id,
          "not-a-uuid",
          Ecto.UUID.generate(),
          known_b.id,
          nil,
          42
        ])

      assert Enum.sort(Map.keys(loaded)) == Enum.sort([known_a.id, known_b.id])
    end

    test "returns an empty map for an empty or unusable list" do
      assert Accounts.users_by_ids([]) == %{}
      assert Accounts.users_by_ids(["nope", nil, :atom]) == %{}
    end

    test "reads N ids in exactly one query, and issues none for an empty list" do
      users = for i <- 1..3, do: Ash.Seed.seed!(User, %{email: "counted-#{i}@example.com"})
      ids = Enum.map(users, & &1.id)

      # Drop the seeding statements so the counts below measure only the reads.
      flush_user_queries()

      assert map_size(Accounts.users_by_ids(ids)) == 3
      assert user_query_count() == 1

      assert Accounts.users_by_ids([]) == %{}
      assert user_query_count() == 0

      # An unknown id is still part of the same single statement.
      with_unknown = Accounts.users_by_ids(ids ++ [Ecto.UUID.generate()])
      assert map_size(with_unknown) == 3
      assert user_query_count() == 1
    end

    test "accepts raw 16-byte ids but keys the map by canonical strings" do
      user = Ash.Seed.seed!(User, %{email: "raw-uuid@example.com", name: "Raw"})
      raw = Ecto.UUID.dump!(user.id)

      assert byte_size(raw) == 16

      loaded = Accounts.users_by_ids([raw])

      assert Map.keys(loaded) == [user.id]
      assert loaded[user.id].id == user.id
      refute Map.has_key?(loaded, raw)
    end
  end

  # Counts statements issued against the `users` table (both reads and the seeds
  # above), so AshPostgres introspection (`pg_catalog`) and sandbox bookkeeping
  # never inflate the count. Ecto derives the prefix from the repo module name
  # (not `otp_app`): `Cadence.Server.Repo` → `[:cadence, :server, :repo, :query]`.
  # Because writes are counted too, a test that seeds must flush first.
  defp attach_user_query_counter do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:cadence, :server, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:source] == "users" do
            send(test_pid, {:user_query, metadata.query})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp flush_user_queries do
    _ = user_query_count()
    :ok
  end

  # Queries run in the caller under the sandbox, so the events are already in
  # the mailbox (and the handler runs synchronously) — `after 0` is enough.
  defp user_query_count(acc \\ 0) do
    receive do
      {:user_query, _query} -> user_query_count(acc + 1)
    after
      0 -> acc
    end
  end

  defp sign_in(api_key) do
    User
    |> Ash.Query.for_read(:sign_in_with_api_key, %{api_key: api_key})
    |> Ash.read_one(domain: Cadence.Server.Accounts)
  end
end
