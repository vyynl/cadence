defmodule Cadence.Server.ReleaseBootstrapTest do
  use Cadence.ServerWeb.ConnCase, async: false

  alias Cadence.Server.Accounts.LocalAuth
  alias Cadence.Server.Release

  test "bootstrap_admin/0 creates the account from CAD_ADMIN_*" do
    email = "bootstrap-env-#{System.unique_integer([:positive])}@example.com"
    keys = ["CAD_ADMIN_EMAIL", "CAD_ADMIN_NAME", "CAD_ADMIN_PASSWORD"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})

    System.put_env("CAD_ADMIN_EMAIL", email)
    System.put_env("CAD_ADMIN_NAME", "Bootstrapped")
    System.put_env("CAD_ADMIN_PASSWORD", "a long bootstrap password")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    assert Release.bootstrap_admin() == :ok
    assert LocalAuth.get_user_by_email_and_password(email, "a long bootstrap password")
  end

  test "ensure_user/3 creates once and leaves an existing account untouched" do
    email = "bootstrap-#{System.unique_integer([:positive])}@example.com"

    assert Release.ensure_user(email, "Bootstrap", "a long password") == :ok
    assert {:ok, user} = LocalAuth.get_by_email(email)
    assert to_string(user.email) == email

    assert Release.ensure_user(email, "Bootstrap", "a different long password") == :ok
    assert LocalAuth.get_user_by_email_and_password(email, "a long password")
    refute LocalAuth.get_user_by_email_and_password(email, "a different long password")
  end
end
