defmodule Cadence.Server.MeldsTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Cadence.ServerFixtures

  alias Cadence.Server.{
    Incident,
    Melds,
    Proposal,
    ProposalView,
    ProjectGit,
    Repo,
    TestMeldLLM
  }

  alias Cadence.Shared.{GitStore, Node}

  @keys [
    :meld_timeout_ms,
    :meld_context_bytes,
    :meld_rate_limit,
    :meld_max_ops,
    :meld_max_file_bytes,
    :meld_retry_attempts,
    :meld_retry_backoff_ms,
    :scan_max_files,
    :scan_max_bytes
  ]

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    previous = Map.new(@keys, &{&1, Application.get_env(:cadence_server, &1)})
    previous_llm = Application.get_env(:cadence_server, :meld_llm)

    Application.put_env(:cadence_server, :meld_llm, TestMeldLLM)
    TestMeldLLM.setup()

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:cadence_server, key)
        {key, value} -> Application.put_env(:cadence_server, key, value)
      end)

      if previous_llm do
        Application.put_env(:cadence_server, :meld_llm, previous_llm)
      else
        Application.delete_env(:cadence_server, :meld_llm)
      end

      TestMeldLLM.reset()
    end)

    :ok
  end

  describe "propose/3 without conflicts" do
    test "materializes the union and never calls the model" do
      {owner, project} = owner_project()
      [parent_a, parent_b] = parents(project, %{"app.txt" => "same"}, %{"app.txt" => "same"})
      before = Repo.aggregate(Node, :count)

      assert {:ok, proposal} =
               Melds.propose(actor(owner), project.id, [parent_a.id, parent_b.id])

      assert proposal.status == :pending
      assert proposal.kind == :meld
      assert proposal.parent_ids == [parent_a.id, parent_b.id]

      meta = proposal.result_metadata
      assert meta["llm"] == "skipped_no_conflicts"
      assert meta["conflict_count"] == 0
      assert meta["file_count"] == 1
      assert meta["ops"] == %{"create" => 0, "modify" => 0, "delete" => 0}
      assert meta["intended_flag"] == "in-progress"
      assert meta["prompt_version"] == "meld-v1"

      assert TestMeldLLM.calls() == 0
      assert Repo.aggregate(Node, :count) == before

      assert {:ok, result} = ProposalView.result(project, proposal)
      assert result.files == []
    end

    test "repeated successes are allowed (no dedupe of proposals)" do
      {owner, project} = owner_project()
      [parent_a, parent_b] = parents(project, %{"a.txt" => "a"}, %{"b.txt" => "b"})
      ids = [parent_a.id, parent_b.id]

      assert {:ok, first} = Melds.propose(actor(owner), project.id, ids)
      assert {:ok, second} = Melds.propose(actor(owner), project.id, ids)
      assert first.id != second.id
    end
  end

  describe "propose/3 with conflicts" do
    test "applies the model ops and records provenance" do
      {owner, project} = owner_project()

      [parent_a, parent_b] =
        parents(
          project,
          %{"keep.txt" => "same", "edit.txt" => "one"},
          %{"keep.txt" => "same", "edit.txt" => "two"}
        )

      TestMeldLLM.script([{:ok, respond_modify("edit.txt", "merged")}])
      before = Repo.aggregate(Node, :count)

      assert {:ok, proposal} =
               Melds.propose(actor(owner), project.id, [parent_a.id, parent_b.id])

      meta = proposal.result_metadata
      assert meta["llm"] == "used"
      assert meta["provider"] == "test-provider"
      assert meta["model"] == "test-meld-model"
      assert meta["prompt_version"] == "meld-v1"
      assert meta["parent_count"] == 2
      assert meta["conflict_count"] == 1
      assert meta["file_count"] == 2
      assert meta["ops"] == %{"create" => 0, "modify" => 1, "delete" => 0}
      assert meta["intended_flag"] == "in-progress"

      assert TestMeldLLM.calls() == 1
      assert Repo.aggregate(Node, :count) == before

      repo = ProjectGit.open(project.id)
      commit = GitStore.read_commit(repo, proposal.meld_commit_sha)
      assert commit.tree == proposal.result_tree_sha
      assert commit.parent == [parent_a.git_commit_sha, parent_b.git_commit_sha]

      assert {:ok, result} = ProposalView.result(project, proposal)
      assert result.files == [%{path: "edit.txt", status: :modified}]
    end

    test "a deleted conflict is removed from the result" do
      {owner, project} = owner_project()

      [parent_a, parent_b] =
        parents(project, %{"gone.txt" => "one"}, %{"gone.txt" => "two"})

      TestMeldLLM.script([{:ok, "MELD_BEGIN\nFILE DELETE gone.txt\nMELD_END\n"}])

      assert {:ok, proposal} =
               Melds.propose(actor(owner), project.id, [parent_a.id, parent_b.id])

      assert proposal.result_metadata["ops"] == %{"create" => 0, "modify" => 0, "delete" => 1}
      assert {:ok, result} = ProposalView.result(project, proposal)
      assert result.files == [%{path: "gone.txt", status: :deleted}]
    end

    test "a provider configuration failure opens one high meld_failed incident" do
      {owner, project} = owner_project()
      [parent_a, parent_b] = conflicting_parents(project)
      TestMeldLLM.script([{:error, :not_configured}])

      assert {:error, {:meld, :not_configured}} =
               Melds.propose(actor(owner), project.id, [parent_a.id, parent_b.id])

      assert Repo.aggregate(Proposal, :count) == 0

      assert [incident] = incidents(project, :meld_failed)
      assert incident.severity == :high
      assert incident.details["reason"] == "not_configured"
      assert incident.details["stage"] == "llm"
      refute inspect(incident.details) =~ "one"
    end

    test "a provider error is redacted and surfaced as llm_error" do
      Application.put_env(:cadence_server, :meld_retry_attempts, 0)
      {owner, project} = owner_project()
      [parent_a, parent_b] = conflicting_parents(project)
      TestMeldLLM.script([{:error, :boom}])

      assert {:error, {:meld, {:llm, :boom}}} =
               Melds.propose(actor(owner), project.id, [parent_a.id, parent_b.id])

      assert [incident] = incidents(project, :meld_failed)
      assert incident.details["reason"] == "llm_error"
      refute inspect(incident.details) =~ "boom"
    end

    test "a timeout opens a high meld_failed incident" do
      Application.put_env(:cadence_server, :meld_timeout_ms, 10)
      {owner, project} = owner_project()
      [parent_a, parent_b] = conflicting_parents(project)
      TestMeldLLM.script([{:sleep, 200}])

      assert {:error, {:meld, :timeout}} =
               Melds.propose(actor(owner), project.id, [parent_a.id, parent_b.id])

      assert [incident] = incidents(project, :meld_failed)
      assert incident.severity == :high
      assert incident.details["reason"] == "timeout"
    end

    test "a context budget that cannot hold every conflict is a critical scan incident" do
      Application.put_env(:cadence_server, :meld_context_bytes, 13)
      {owner, project} = owner_project()

      [parent_a, parent_b] =
        parents(
          project,
          %{"a.txt" => "one", "b.txt" => "two"},
          %{"a.txt" => "uno", "b.txt" => "dos"}
        )

      assert {:error, {:meld, :context_too_large}} =
               Melds.propose(actor(owner), project.id, [parent_a.id, parent_b.id])

      assert TestMeldLLM.calls() == 0
      assert [incident] = incidents(project, :scan_incomplete)
      assert incident.severity == :critical
      assert incident.details["reason"] == "context_too_large"
    end
  end

  describe "agent output validation" do
    test "malformed, unknown, duplicate, unsafe, and non-conflicting ops are rejected" do
      {owner, project} = owner_project()

      [parent_a, parent_b] =
        parents(
          project,
          %{"keep.txt" => "same", "edit.txt" => "one"},
          %{"keep.txt" => "same", "edit.txt" => "two"}
        )

      ids = [parent_a.id, parent_b.id]

      cases = [
        {"missing MELD_END", "MELD_BEGIN\nFILE MODIFY edit.txt\n<<<\nmerged\n"},
        {"unknown path", "MELD_BEGIN\nFILE MODIFY other.txt\n<<<\nx\n>>>\nMELD_END\n"},
        {"non-conflicting path", "MELD_BEGIN\nFILE MODIFY keep.txt\n<<<\nx\n>>>\nMELD_END\n"},
        {"duplicate path",
         "MELD_BEGIN\nFILE MODIFY edit.txt\n<<<\na\n>>>\nFILE DELETE edit.txt\nMELD_END\n"},
        {"unsafe path", "MELD_BEGIN\nFILE MODIFY ../escape\nMELD_END\n"}
      ]

      for {label, text} <- cases do
        TestMeldLLM.script([{:ok, text}])

        assert {:error, :invalid_agent_output} = Melds.propose(actor(owner), project.id, ids),
               "case: #{label}"
      end

      assert Repo.aggregate(Proposal, :count) == 0
      assert [incident] = incidents(project, :agent_output_invalid)
      assert incident.severity == :high
    end

    test "a binary conflict fails before any model call" do
      {owner, project} = owner_project()

      [parent_a, parent_b] =
        parents(project, %{"bin.dat" => <<0, 1, 2>>}, %{"bin.dat" => <<3, 4, 5>>})

      assert {:error, :invalid_agent_output} =
               Melds.propose(actor(owner), project.id, [parent_a.id, parent_b.id])

      assert TestMeldLLM.calls() == 0
      assert [incident] = incidents(project, :agent_output_invalid)
      assert incident.details["reason"] == "binary_content"
    end

    test "an Elixir syntax error is rejected" do
      {owner, project} = owner_project()

      [parent_a, parent_b] =
        parents(
          project,
          %{"app.ex" => "defmodule App do\n  def a, do: 1\nend\n"},
          %{"app.ex" => "defmodule App do\n  def a, do: 2\nend\n"}
        )

      TestMeldLLM.script([{:ok, respond_modify("app.ex", "defmodule App do")}])

      assert {:error, :invalid_agent_output} =
               Melds.propose(actor(owner), project.id, [parent_a.id, parent_b.id])

      assert TestMeldLLM.calls() == 1
      assert [incident] = incidents(project, :agent_output_invalid)
      assert incident.details["reason"] == "syntax_error"
    end
  end

  describe "secret detection" do
    test "a secret in the result keeps the proposal but opens a critical incident" do
      {owner, project} = owner_project()

      [parent_a, parent_b] =
        parents(
          project,
          %{"config.txt" => "token=one"},
          %{"config.txt" => "token=two"}
        )

      secret = "ghp_" <> String.duplicate("A", 20)
      TestMeldLLM.script([{:ok, respond_modify("config.txt", "token=#{secret}")}])

      assert {:ok, proposal} =
               Melds.propose(actor(owner), project.id, [parent_a.id, parent_b.id])

      assert ProposalView.isolated?(proposal)

      assert [incident] = incidents(project, :secret_detected)
      assert incident.severity == :critical
      assert incident.proposal_id == proposal.id
      assert "github_token" in incident.details["patterns"]
      refute inspect(incident.details) =~ secret
    end

    test "ordinary result text does not open a secret incident" do
      {owner, project} = owner_project()

      [parent_a, parent_b] =
        parents(project, %{"state.txt" => "one"}, %{"state.txt" => "two"})

      TestMeldLLM.script([{:ok, respond_modify("state.txt", "merged")}])

      assert {:ok, _proposal} =
               Melds.propose(actor(owner), project.id, [parent_a.id, parent_b.id])

      assert incidents(project, :secret_detected) == []
    end
  end

  describe "parent scan failures" do
    test "exceeding the scan caps opens a critical scan_incomplete incident" do
      Application.put_env(:cadence_server, :scan_max_files, 1)
      {owner, project} = owner_project()

      [parent_a, parent_b] =
        parents(project, %{"one.txt" => "1", "two.txt" => "2"}, %{"one.txt" => "1"})

      assert {:error, {:scan, :too_many_files}} =
               Melds.propose(actor(owner), project.id, [parent_a.id, parent_b.id])

      assert Repo.aggregate(Proposal, :count) == 0
      assert [incident] = incidents(project, :scan_incomplete)
      assert incident.severity == :critical
      assert incident.details["stage"] == "parent_scan"
    end

    test "missing parent objects open a high missing_objects incident" do
      {owner, project} = owner_project()

      parent_a = node_fixture(project, %{git_commit_sha: String.duplicate("b", 40)})
      parent_b = node_with_snapshot(project, %{"x.txt" => "x"})

      assert {:error, {:scan, :missing_object}} =
               Melds.propose(actor(owner), project.id, [parent_a.id, parent_b.id])

      assert Repo.aggregate(Proposal, :count) == 0
      assert [incident] = incidents(project, :missing_objects)
      assert incident.severity == :high
    end
  end

  describe "authorization and input shape" do
    test "owner and trusted may propose; viewer, stranger, and foreign owners may not" do
      owner = Ecto.UUID.generate()
      trusted = Ecto.UUID.generate()
      viewer = Ecto.UUID.generate()
      stranger = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      membership(project, trusted, :trusted)
      membership(project, viewer, :viewer)

      [parent_a, parent_b] = parents(project, %{"a.txt" => "a"}, %{"b.txt" => "b"})
      ids = [parent_a.id, parent_b.id]

      assert {:ok, _proposal} = Melds.propose(actor(owner), project.id, ids)
      assert {:ok, _proposal} = Melds.propose(actor(trusted), project.id, ids)
      assert Melds.propose(actor(viewer), project.id, ids) == {:error, :forbidden}
      assert Melds.propose(actor(stranger), project.id, ids) == {:error, :forbidden}

      foreign_owner = Ecto.UUID.generate()
      foreign = project(foreign_owner)
      membership(foreign, foreign_owner, :owner)

      assert Melds.propose(actor(foreign_owner), project.id, ids) == {:error, :forbidden}
    end

    test "invalid parent shapes and unknown projects are rejected" do
      {owner, project} = owner_project()
      [parent_a, parent_b] = parents(project, %{"a.txt" => "a"}, %{"b.txt" => "b"})

      assert Melds.propose(actor(owner), project.id, [parent_a.id]) == {:error, :invalid_parent}

      assert Melds.propose(actor(owner), project.id, [parent_a.id, parent_a.id]) ==
               {:error, :invalid_parent}

      assert Melds.propose(actor(owner), project.id, [parent_a.id, "not-a-uuid"]) ==
               {:error, :invalid_parent}

      _other_owner = Ecto.UUID.generate()
      foreign_project = project(Ecto.UUID.generate())
      foreign = node_with_snapshot(foreign_project, %{"f.txt" => "f"})

      assert Melds.propose(actor(owner), project.id, [parent_a.id, foreign.id]) ==
               {:error, :invalid_parent}

      ids = [parent_a.id, parent_b.id]
      assert Melds.propose(actor(owner), Ecto.UUID.generate(), ids) == {:error, :not_found}
      assert Melds.propose(actor(owner), "not-a-uuid", ids) == {:error, :not_found}
    end
  end

  test "repeated failures reuse one open project incident" do
    {owner, project} = owner_project()
    [parent_a, parent_b] = conflicting_parents(project)
    ids = [parent_a.id, parent_b.id]

    TestMeldLLM.script([{:error, :not_configured}, {:error, :not_configured}])

    assert {:error, {:meld, :not_configured}} = Melds.propose(actor(owner), project.id, ids)
    assert {:error, {:meld, :not_configured}} = Melds.propose(actor(owner), project.id, ids)

    assert [incident] = incidents(project, :meld_failed)
    assert Repo.aggregate(from(i in Incident, where: i.kind == :meld_failed), :count) == 1
    assert incident.severity == :high
  end

  ## Helpers

  defp owner_project do
    owner = Ecto.UUID.generate()
    project = project(owner)
    membership(project, owner, :owner)
    {owner, project}
  end

  defp parents(project, files_a, files_b) do
    [
      node_with_snapshot(project, files_a, %{message: "parent a"}),
      node_with_snapshot(project, files_b, %{message: "parent b"})
    ]
  end

  defp conflicting_parents(project) do
    parents(project, %{"edit.txt" => "one"}, %{"edit.txt" => "two"})
  end

  defp respond_modify(path, content) do
    "MELD_BEGIN\nFILE MODIFY #{path}\n<<<\n#{content}\n>>>\nMELD_END\n"
  end

  defp incidents(project, kind) do
    Repo.all(
      from(i in Incident,
        where: i.project_id == ^project.id and i.kind == ^kind,
        order_by: [asc: i.created_at, asc: i.id]
      )
    )
  end

  defp actor(user_id), do: %{id: user_id}
end
