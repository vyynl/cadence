defmodule Cadence.Server.AuthorizationTest do
  use ExUnit.Case, async: false

  import Cadence.ServerFixtures

  alias Cadence.Server.{Authorization, Repo}
  alias Cadence.Shared.Membership

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "role predicates" do
    test "owners can view, propose, manage, and decide" do
      membership = %Membership{role: :owner}

      assert Authorization.can_view?(membership)
      assert Authorization.can_propose?(membership)
      assert Authorization.can_manage?(membership)
      assert Authorization.can_decide?(membership)
    end

    test "trusted members manage but only decide with the approver grant" do
      membership = %Membership{role: :trusted, approver: false}

      assert Authorization.can_view?(membership)
      assert Authorization.can_propose?(membership)
      assert Authorization.can_manage?(membership)
      refute Authorization.can_decide?(membership)

      assert Authorization.can_decide?(%{membership | approver: true})
    end

    test "viewers can only view" do
      membership = %Membership{role: :viewer}

      assert Authorization.can_view?(membership)
      refute Authorization.can_propose?(membership)
      refute Authorization.can_manage?(membership)
      refute Authorization.can_decide?(membership)
    end

    test "a missing membership can do nothing" do
      refute Authorization.can_view?(nil)
      refute Authorization.can_propose?(nil)
      refute Authorization.can_manage?(nil)
      refute Authorization.can_decide?(nil)
    end
  end

  describe "membership/2" do
    test "returns the row for a member and nil otherwise" do
      user = Ecto.UUID.generate()
      project = project(user)
      membership(project, user, :viewer)

      assert %Membership{} = Authorization.membership(user, project.id)
      assert Authorization.membership(Ecto.UUID.generate(), project.id) == nil
      assert Authorization.membership(user, Ecto.UUID.generate()) == nil
      assert Authorization.membership("not-a-uuid", project.id) == nil

      assert Repo.aggregate(Membership, :count) == 1
    end
  end
end
