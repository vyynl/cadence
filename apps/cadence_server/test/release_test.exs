defmodule Cadence.Server.ReleaseTest do
  use ExUnit.Case, async: true

  alias Cadence.Server.Release
  alias Cadence.Server.Repo

  test "repos/0 returns the server repo" do
    assert Release.repos() == [Repo]
  end

  test "migrations_path/1 resolves the app's priv/repo/migrations" do
    assert Release.migrations_path(Repo) ==
             Application.app_dir(:cadence_server, "priv/repo/migrations")
  end

  describe "admin_config/1" do
    test "skips when both admin values are absent or blank" do
      assert Release.admin_config(%{}) == :skip

      assert Release.admin_config(%{"CAD_ADMIN_EMAIL" => " ", "CAD_ADMIN_PASSWORD" => ""}) ==
               :skip
    end

    test "returns trimmed attributes when the pair is complete" do
      assert Release.admin_config(%{
               "CAD_ADMIN_EMAIL" => "  admin@example.com ",
               "CAD_ADMIN_NAME" => " Admin ",
               "CAD_ADMIN_PASSWORD" => "a long password"
             }) ==
               {:ok,
                %{
                  email: "admin@example.com",
                  name: "Admin",
                  password: "a long password"
                }}
    end

    test "a blank password skips even when an email remains" do
      assert Release.admin_config(%{"CAD_ADMIN_EMAIL" => "a@b.c"}) == :skip
    end

    test "a password without an email is an actionable error" do
      assert {:error, message} = Release.admin_config(%{"CAD_ADMIN_PASSWORD" => "secret"})
      assert message =~ "CAD_ADMIN_EMAIL"
    end
  end
end
