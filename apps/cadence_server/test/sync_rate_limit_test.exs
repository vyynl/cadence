defmodule Cadence.ServerWeb.SyncRateLimitTest do
  @moduledoc """
  Request-level acceptance for the per-user `/sync/*` rate limit (spec §10.1).

  The limiter is off in `config/test.exs`; each test opts in with
  `Application.put_env/3` and restores the previous values on exit. The Hammer
  ETS table is VM-global, so keys are unique per test (a fresh seeded user) and
  no test relies on a table reset.
  """

  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.User

  @keys [:sync_rate_limit, :sync_rate_scale]

  setup do
    previous = Map.new(@keys, &{&1, Application.get_env(:cadence_server, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:cadence_server, key)
        {key, value} -> Application.put_env(:cadence_server, key, value)
      end)
    end)

    # A ten-minute window keeps every request of a test inside one fixed-window
    # bucket, so an assertion cannot straddle a window boundary.
    Application.put_env(:cadence_server, :sync_rate_scale, 600_000)
    :ok
  end

  test "allows requests up to the configured limit" do
    Application.put_env(:cadence_server, :sync_rate_limit, 3)

    %{user: user, plaintext: plaintext} = user_with_key("under-limit")

    for _ <- 1..3 do
      response = me(plaintext)

      assert response.status == 200
      assert json_response(response, 200)["user_id"] == user.id
    end
  end

  test "denies past the limit with 429, Retry-After, and a JSON error" do
    Application.put_env(:cadence_server, :sync_rate_limit, 2)

    %{plaintext: plaintext} = user_with_key("over-limit")

    assert me(plaintext).status == 200
    assert me(plaintext).status == 200

    response = me(plaintext)

    assert response.status == 429
    assert response.resp_body == ~s({"error":"rate_limited"})
    assert get_resp_header(response, "content-type") == ["application/json; charset=utf-8"]

    assert [retry_after] = get_resp_header(response, "retry-after")
    # Seconds, not milliseconds: the test window is 600 s.
    assert String.to_integer(retry_after) in 1..600
  end

  test "a different user is unaffected by another user's exhaustion" do
    Application.put_env(:cadence_server, :sync_rate_limit, 1)

    %{plaintext: exhausted} = user_with_key("exhausted")
    %{plaintext: other} = user_with_key("other")

    assert me(exhausted).status == 200
    assert me(exhausted).status == 429

    assert me(other).status == 200
  end

  test "keys one bucket per user, not per API key" do
    Application.put_env(:cadence_server, :sync_rate_limit, 2)

    user = seed_user("two-keys")
    key_a = api_key(user, "a")
    key_b = api_key(user, "b")

    assert me(key_a).status == 200
    assert me(key_a).status == 200
    assert me(key_b).status == 429
  end

  test "a denied mutating request never reaches the controller" do
    Application.put_env(:cadence_server, :sync_rate_limit, 1)

    %{plaintext: plaintext} = user_with_key("post-limit")
    first_slug = unique_slug("first")
    second_slug = unique_slug("second")

    created = provision(plaintext, first_slug)

    assert json_response(created, 201)["project"]["slug"] == first_slug

    denied = provision(plaintext, second_slug)

    assert denied.status == 429
    assert json_response(denied, 429) == %{"error" => "rate_limited"}

    assert Cadence.Server.Portfolio.get_project_by_slug(second_slug) == {:error, :not_found}
  end

  test "an unauthenticated request is rejected before the limiter" do
    Application.put_env(:cadence_server, :sync_rate_limit, 1)

    assert me("garbage").status == 401
    assert me("garbage").status == 401

    %{plaintext: plaintext} = user_with_key("after-401")

    assert me(plaintext).status == 200
  end

  test "a non-positive limit disables the bound" do
    Application.put_env(:cadence_server, :sync_rate_limit, 0)

    %{plaintext: plaintext} = user_with_key("disabled")

    for _ <- 1..3 do
      assert me(plaintext).status == 200
    end
  end

  test "reads the limit at call time" do
    Application.put_env(:cadence_server, :sync_rate_limit, 1)

    %{plaintext: plaintext} = user_with_key("live-config")

    assert me(plaintext).status == 200
    assert me(plaintext).status == 429

    # Same fix-window bucket: the stored count (2) is now under the new limit.
    Application.put_env(:cadence_server, :sync_rate_limit, 5)

    assert me(plaintext).status == 200
  end

  test "a non-integer or non-positive window falls back to the defaults" do
    for value <- [nil, "nope", :nope] do
      Application.put_env(:cadence_server, :sync_rate_limit, value)
      Application.put_env(:cadence_server, :sync_rate_scale, value)

      assert Cadence.ServerWeb.Plugs.SyncRateLimit.limit() == 300
      assert Cadence.ServerWeb.Plugs.SyncRateLimit.scale() == 60_000
    end

    for value <- [0, -1] do
      Application.put_env(:cadence_server, :sync_rate_scale, value)

      assert Cadence.ServerWeb.Plugs.SyncRateLimit.scale() == 60_000
    end
  end

  defp me(plaintext) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{plaintext}")
    |> put_req_header("accept", "application/json")
    |> get("/sync/me")
  end

  defp provision(plaintext, slug) do
    body = %{
      "project" => %{"id" => Ecto.UUID.generate(), "name" => "Provisioned", "slug" => slug}
    }

    build_conn()
    |> put_req_header("authorization", "Bearer #{plaintext}")
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> post("/sync/projects", Jason.encode!(body))
  end

  defp user_with_key(label) do
    user = seed_user(label)

    %{user: user, plaintext: api_key(user, label)}
  end

  defp api_key(user, label) do
    {:ok, api_key} = Accounts.create_api_key(user, "sync-rate-#{label}")
    api_key.__metadata__.plaintext_api_key
  end

  defp unique_slug(label) do
    "sync-rate-#{label}-#{System.unique_integer([:positive])}"
  end

  defp seed_user(label) do
    Ash.Seed.seed!(User, %{
      email: "sync-rate-#{label}-#{System.unique_integer([:positive])}@example.com",
      name: label
    })
  end
end
