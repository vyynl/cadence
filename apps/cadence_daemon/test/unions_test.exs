defmodule Cadence.Daemon.UnionsTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{Repo, UnionProposal, Unions}
  alias Cadence.Shared.Project

  test "lists newest first and scopes by project" do
    project = insert_project()
    other = insert_project()

    _older = insert_row(project.id, ~U[2026-11-08 01:00:00.000000Z], "older")
    _newer = insert_row(project.id, ~U[2026-11-08 02:00:00.000000Z], "newer")
    _elsewhere = insert_row(other.id, ~U[2026-11-08 03:00:00.000000Z], "other")

    assert Enum.map(Unions.list(project.id), & &1.token) == ["newer", "older"]
    assert Enum.map(Unions.list(other.id), & &1.token) == ["other"]
    assert Unions.list(Ecto.UUID.generate()) == []
    assert Unions.list("not-a-uuid") == []
    assert Unions.list(project.id, 0) == []
  end

  test "record upserts by proposal id and keeps the first created_at" do
    project = insert_project()
    id = Ecto.UUID.generate()
    parents = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    {:ok, first} =
      Unions.record(
        project.id,
        %{proposal_id: id, proposal_token: "tok-1", status: "pending", kind: "meld"},
        [hd(parents)]
      )

    {:ok, second} =
      Unions.record(
        project.id,
        %{proposal_id: id, proposal_token: "tok-2", status: "pending", kind: "meld"},
        parents
      )

    assert second.id == id
    assert second.token == "tok-2"
    assert second.parent_node_ids == parents
    assert second.created_at == first.created_at
    assert [%{token: "tok-2"}] = Unions.list(project.id)
  end

  test "record keeps the newest 20 per project and leaves other projects alone" do
    project = insert_project()
    other = insert_project()
    base = ~U[2020-01-01 00:00:00.000000Z]

    for index <- 0..19 do
      insert_row(project.id, DateTime.add(base, index, :second), "project-#{index}")
      insert_row(other.id, DateTime.add(base, index, :second), "other-#{index}")
    end

    {:ok, _row} =
      Unions.record(
        project.id,
        %{
          proposal_id: Ecto.UUID.generate(),
          proposal_token: "newest",
          status: "pending",
          kind: "meld"
        },
        []
      )

    tokens = project.id |> Unions.list(50) |> Enum.map(& &1.token)

    assert length(tokens) == 20
    refute "project-0" in tokens
    assert Enum.sort(tokens) == Enum.sort(["newest" | for(i <- 1..19, do: "project-#{i}")])
    assert length(Unions.list(other.id, 50)) == 20
  end

  test "record rejects an unusable response without writing" do
    project = insert_project()

    assert {:error, :invalid_proposal} =
             Unions.record(project.id, %{proposal_id: "nope", proposal_token: "tok"}, [])

    assert {:error, :invalid_proposal} =
             Unions.record(
               project.id,
               %{proposal_id: Ecto.UUID.generate(), proposal_token: ""},
               []
             )

    assert {:error, :invalid_proposal} = Unions.record(project.id, proposal(), ["not-a-uuid"])
    assert {:error, :invalid_proposal} = Unions.record("not-a-uuid", proposal(), [])
    assert Unions.list(project.id) == []
  end

  test "get/2 accepts an id or token within the project" do
    project = insert_project()
    other = insert_project()
    {:ok, row} = Unions.record(project.id, proposal(), [])

    assert %{id: id} = Unions.get(project.id, row.id)
    assert %{id: ^id} = Unions.get(project.id, row.token)
    assert Unions.get(other.id, row.id) == nil
    assert Unions.get(project.id, "unknown") == nil
    assert Unions.get(project.id, nil) == nil
  end

  defp proposal do
    %{
      proposal_id: Ecto.UUID.generate(),
      proposal_token: "tok-#{System.unique_integer([:positive])}",
      status: "pending",
      kind: "meld"
    }
  end

  defp insert_row(project_id, created_at, token) do
    %UnionProposal{}
    |> UnionProposal.changeset(%{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      token: token,
      kind: "meld",
      status: "pending",
      parent_node_ids: [Ecto.UUID.generate()],
      created_at: created_at
    })
    |> Repo.insert!()
  end

  defp insert_project do
    %{
      name: "unions",
      slug: "unions-#{System.unique_integer([:positive])}",
      owner_id: Ecto.UUID.generate()
    }
    |> Project.changeset()
    |> Repo.insert!()
  end
end
