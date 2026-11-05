defmodule Cadence.Server.NodeScansTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  import Cadence.ServerFixtures

  alias Cadence.Server.{Incident, NodeScans, Repo}

  @secret "ghp_abcdefghijklmnopqrstuvwxyz0123456789"

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "scan_node/2" do
    test "opens a critical secret incident for a secret value" do
      project = project(Ecto.UUID.generate())

      node =
        node_with_snapshot(project, %{
          "README.md" => "# Secret\n",
          "config.txt" => "token: #{@secret}\n"
        })

      assert :ok = NodeScans.scan_node(project.id, node)

      assert [incident] = open_incidents(project)
      assert incident.kind == :secret_detected
      assert incident.severity == :critical
      assert incident.node_id == node.id
      assert incident.details["stage"] == "push_scan"
      assert "github_token" in incident.details["patterns"]
      assert incident.details["sensitive_paths"] == 0
    end

    test "opens a critical incident for a sensitive non-example path" do
      project = project(Ecto.UUID.generate())

      node =
        node_with_snapshot(project, %{
          ".env" => "SAFE=1\n",
          "README.md" => "# Env\n"
        })

      assert :ok = NodeScans.scan_node(project.id, node)

      assert [incident] = open_incidents(project)
      assert incident.kind == :secret_detected
      assert incident.severity == :critical
      assert incident.details["sensitive_paths"] == 1
      assert incident.details["patterns"] == []
    end

    test "opens nothing for a clean snapshot" do
      project = project(Ecto.UUID.generate())

      node =
        node_with_snapshot(project, %{
          "README.md" => "# Clean\n",
          "src/app.ex" => "defmodule App do\nend\n"
        })

      assert :ok = NodeScans.scan_node(project.id, node)
      assert open_incidents(project) == []
    end

    test "opens a critical scan_incomplete incident when the file cap overflows" do
      with_scan_limit(:scan_max_files, 1, fn ->
        project = project(Ecto.UUID.generate())

        node =
          node_with_snapshot(project, %{
            "README.md" => "# Clean\n",
            "src/app.ex" => "defmodule App do\nend\n"
          })

        assert :ok = NodeScans.scan_node(project.id, node)

        assert [incident] = open_incidents(project)
        assert incident.kind == :scan_incomplete
        assert incident.severity == :critical
        assert incident.details["stage"] == "push_scan"
        assert incident.details["reason"] == "too_many_files"
      end)
    end

    test "opens a high missing_objects incident for an unreadable snapshot" do
      project = project(Ecto.UUID.generate())
      # Ensure the project store exists, then point the node at a bogus commit.
      _existing = node_with_snapshot(project, %{"README.md" => "# One\n"})
      node = node_fixture(project, %{git_commit_sha: String.duplicate("b", 40)})

      assert :ok = NodeScans.scan_node(project.id, node)

      assert [incident] = open_incidents(project)
      assert incident.kind == :missing_objects
      assert incident.severity == :high
      assert incident.details["reason"] == "missing_object"
    end

    test "repeated scans reuse the single open incident" do
      project = project(Ecto.UUID.generate())
      node = node_with_snapshot(project, %{"config.txt" => "token: #{@secret}\n"})

      assert :ok = NodeScans.scan_node(project.id, node)
      assert [first] = open_incidents(project)

      assert :ok = NodeScans.scan_node(project.id, node)
      assert [second] = open_incidents(project)
      assert second.id == first.id
      assert Repo.aggregate(Incident, :count) == 1
    end

    test "details never contain the secret value or file content" do
      project = project(Ecto.UUID.generate())

      node =
        node_with_snapshot(project, %{
          "config.txt" => "deploy_key: #{@secret}\n",
          "notes.md" => "# Notes\n"
        })

      assert :ok = NodeScans.scan_node(project.id, node)

      assert [incident] = open_incidents(project)
      details = inspect(incident.details)

      refute details =~ @secret
      refute details =~ "deploy_key"
      refute details =~ "# Notes"
    end
  end

  describe "scan_nodes/2" do
    test "scans every node in a mixed batch" do
      project = project(Ecto.UUID.generate())

      clean =
        node_with_snapshot(project, %{
          "README.md" => "# Clean\n",
          "src/app.ex" => "defmodule App do\nend\n"
        })

      secret = node_with_snapshot(project, %{"config.txt" => "token: #{@secret}\n"})

      assert :ok = NodeScans.scan_nodes(project.id, [clean, secret])

      assert [incident] = open_incidents(project)
      assert incident.node_id == secret.id
      assert incident.kind == :secret_detected
    end

    test "an empty batch is a no-op" do
      project = project(Ecto.UUID.generate())

      assert :ok = NodeScans.scan_nodes(project.id, [])
      assert open_incidents(project) == []
    end
  end

  defp open_incidents(project) do
    Repo.all(
      from(i in Incident,
        where: i.project_id == ^project.id and i.status == :open,
        order_by: [asc: i.id]
      )
    )
  end

  defp with_scan_limit(key, value, fun) do
    previous = Application.get_env(:cadence_server, key)
    Application.put_env(:cadence_server, key, value)
    on_exit(fn -> restore_env(key, previous) end)
    fun.()
  end

  defp restore_env(key, nil), do: Application.delete_env(:cadence_server, key)
  defp restore_env(key, value), do: Application.put_env(:cadence_server, key, value)
end
