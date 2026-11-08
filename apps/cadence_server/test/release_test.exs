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
end
