defmodule Cadence.Server.Passkeys.ConfigTest do
  use ExUnit.Case, async: true

  alias Cadence.Server.Passkeys.Config

  defp config(overrides) do
    Config.get()
    |> Map.from_struct()
    |> Map.merge(overrides)
  end

  test "accepts localhost http in dev" do
    assert :ok =
             Config.validate(
               config(%{rp_id: "localhost", origin: "http://localhost:4000"}),
               :dev
             )
  end

  test "accepts 127.0.0.1 and [::1] http in dev" do
    assert :ok =
             Config.validate(
               config(%{rp_id: "127.0.0.1", origin: "http://127.0.0.1:4000"}),
               :dev
             )

    assert :ok =
             Config.validate(config(%{rp_id: "::1", origin: "http://[::1]:4000"}), :dev)
  end

  test "accepts a production https origin with the same RP ID" do
    assert :ok =
             Config.validate(
               config(%{rp_id: "cadence.example.com", origin: "https://cadence.example.com"}),
               :prod
             )
  end

  test "accepts a subdomain origin" do
    assert :ok =
             Config.validate(
               config(%{rp_id: "cadence.example.com", origin: "https://app.cadence.example.com"}),
               :prod
             )
  end

  test "rejects an RP ID with a scheme, port, or path" do
    for rp_id <- [
          "https://cadence.example.com",
          "cadence.example.com:4000",
          "cadence.example.com/path"
        ] do
      assert {:error, message} =
               Config.validate(
                 config(%{rp_id: rp_id, origin: "https://cadence.example.com"}),
                 :prod
               )

      assert message =~ "hostname only"
    end
  end

  test "rejects uppercase, empty labels, and non-loopback IP literals as RP IDs" do
    for rp_id <- ["Cadence.example.com", ".cadence.example.com", "a..b", "192.168.1.10"] do
      assert {:error, _message} =
               Config.validate(
                 config(%{rp_id: rp_id, origin: "https://cadence.example.com"}),
                 :prod
               )
    end
  end

  test "rejects an origin with a path, query, or fragment" do
    for origin <- [
          "https://cadence.example.com/",
          "https://cadence.example.com/path",
          "https://cadence.example.com?x=1",
          "https://cadence.example.com#frag"
        ] do
      assert {:error, message} =
               Config.validate(config(%{rp_id: "cadence.example.com", origin: origin}), :prod)

      assert message =~ "must not include"
    end
  end

  test "rejects an origin whose host is unrelated to the RP ID" do
    assert {:error, message} =
             Config.validate(
               config(%{rp_id: "cadence.example.com", origin: "https://evil.example.com"}),
               :prod
             )

    assert message =~ "must equal"
  end

  test "requires https outside localhost, but allows loopback http in dev" do
    assert {:error, message} =
             Config.validate(
               config(%{rp_id: "cadence.example.com", origin: "http://cadence.example.com"}),
               :dev
             )

    assert message =~ "https"
  end

  test "requires https in production even for localhost" do
    assert {:error, message} =
             Config.validate(
               config(%{rp_id: "localhost", origin: "http://localhost:4000"}),
               :prod
             )

    assert message =~ "https in production"
  end

  test "requires an origin in production" do
    for origin <- [nil, ""] do
      assert {:error, message} =
               Config.validate(config(%{rp_id: "cadence.example.com", origin: origin}), :prod)

      assert message =~ "required in production"
    end
  end

  test "requires an origin when enabled outside production" do
    for origin <- [nil, ""] do
      assert {:error, message} = Config.validate(config(%{origin: origin}), :dev)
      assert message =~ "required"
    end
  end

  test "validates numeric settings and user verification" do
    assert {:error, _} = Config.validate(config(%{user_verification: "sometimes"}), :dev)
    assert {:error, _} = Config.validate(config(%{timeout_ms: 0}), :dev)
    assert {:error, _} = Config.validate(config(%{max_credentials: 0}), :dev)
    assert {:error, _} = Config.validate(config(%{rate_limit: "10"}), :dev)
    assert {:error, _} = Config.validate(config(%{rate_scale: 0}), :dev)
  end

  test "validate!/2 raises with the reason" do
    error =
      assert_raise RuntimeError, fn ->
        Config.validate!(config(%{rp_id: "https://bad.example"}), :prod)
      end

    assert error.message =~ "Invalid WebAuthn configuration"
    assert error.message =~ "hostname only"
  end
end
