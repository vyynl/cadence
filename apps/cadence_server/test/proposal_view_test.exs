defmodule Cadence.Server.ProposalViewTest do
  use ExUnit.Case, async: false

  import Cadence.ServerFixtures

  alias Cadence.Server.{Incidents, Portfolio, ProposalCache, ProposalView, Repo}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # Content-keyed entries are process-global; clear them so a payload can
    # never leak between tests (including into other test files).
    ProposalCache.clear()
    on_exit(&ProposalCache.clear/0)

    owner = Ecto.UUID.generate()
    project = project(owner)
    membership(project, owner, :owner)

    %{owner: owner, project: project}
  end

  describe "Portfolio.get_project/1" do
    test "fetches by UUID and fails closed on unknown or malformed input", %{project: project} do
      assert {:ok, fetched} = Portfolio.get_project(project.id)
      assert fetched.id == project.id

      assert {:error, :not_found} = Portfolio.get_project(Ecto.UUID.generate())
      assert {:error, :not_found} = Portfolio.get_project("not-a-uuid")
      assert {:error, :not_found} = Portfolio.get_project(nil)
    end
  end

  describe "result/2" do
    test "classifies added, modified, and deleted files against the first parent", %{
      owner: owner,
      project: project
    } do
      parent =
        node_with_snapshot(project, %{
          "keep.txt" => "same",
          "gone.txt" => "bye",
          "edit.txt" => "v1"
        })

      other_parent = node_with_snapshot(project, %{"unrelated.txt" => "ignored"})

      result =
        snapshot_tree(project, %{"keep.txt" => "same", "edit.txt" => "v2", "new.txt" => "hi"})

      proposal = meld_proposal(project, owner, [parent, other_parent], result)

      assert {:ok, view} = ProposalView.result(project, proposal)

      assert view.files == [
               %{path: "edit.txt", status: :modified},
               %{path: "gone.txt", status: :deleted},
               %{path: "new.txt", status: :added}
             ]

      assert view.summary == %{added: 1, modified: 1, deleted: 1}
      assert view.hidden_count == 0
      refute view.quarantined?
      refute view.truncated?
    end

    test "hides sensitive paths, counts them, and keeps the rest of the diff", %{
      owner: owner,
      project: project
    } do
      parent = node_with_snapshot(project, %{"notes.txt" => "one"})
      result = snapshot_tree(project, %{"notes.txt" => "two", ".env" => "plain-value"})
      proposal = meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result)

      assert {:ok, view} = ProposalView.result(project, proposal)
      assert view.hidden_count == 1
      assert view.files == [%{path: "notes.txt", status: :modified}]
      refute Enum.any?(view.files, &(&1.path == ".env"))
      refute view.quarantined?
    end

    test "quarantines when the visible result contains a secret value", %{
      owner: owner,
      project: project
    } do
      parent = node_with_snapshot(project, %{"config.txt" => "token: none\n"})

      result =
        snapshot_tree(project, %{
          "config.txt" => "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789\n"
        })

      proposal = meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result)

      assert {:ok, view} = ProposalView.result(project, proposal)
      assert view.quarantined?
    end

    test "returns :missing_objects when the result commit is not present", %{
      owner: owner,
      project: project
    } do
      parent = node_with_snapshot(project, %{"a.txt" => "a"})
      result = snapshot_tree(project, %{"a.txt" => "b"})
      bogus = String.duplicate("b", 40)

      proposal =
        meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result, %{
          meld_commit_sha: bogus,
          result_tree_sha: bogus
        })

      assert ProposalView.result(project, proposal) == {:error, :missing_objects}
    end

    test "returns :too_large when the result exceeds the scan caps", %{
      owner: owner,
      project: project
    } do
      parent = node_with_snapshot(project, %{"small.txt" => "small"})
      result = snapshot_tree(project, %{"large.txt" => String.duplicate("a", 70_000)})
      proposal = meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result)

      assert ProposalView.result(project, proposal) == {:error, :too_large}
    end

    test "returns :none for promotions", %{owner: owner, project: project} do
      node = node_with_snapshot(project, %{"a.txt" => "a"})
      proposal = promotion_proposal(project, owner, node)

      assert ProposalView.result(project, proposal) == :none
    end

    test "returns :missing_objects when the first parent is absent", %{
      owner: owner,
      project: project
    } do
      parent = node_with_snapshot(project, %{"a.txt" => "a"})
      result = snapshot_tree(project, %{"a.txt" => "b"})

      proposal =
        proposal(%{
          project_id: project.id,
          proposer_id: owner,
          kind: :meld,
          parent_ids: [Ecto.UUID.generate(), parent.id],
          result_tree_sha: result.tree,
          meld_commit_sha: result.commit
        })

      assert ProposalView.result(project, proposal) == {:error, :missing_objects}
    end

    test "returns :missing_objects when a parent commit object is absent", %{
      owner: owner,
      project: project
    } do
      unreplicated = node_fixture(project, %{git_commit_sha: String.duplicate("c", 40)})
      result = snapshot_tree(project, %{"a.txt" => "b"})

      proposal =
        meld_proposal(
          project,
          owner,
          [unreplicated, node_with_snapshot(project, %{})],
          result
        )

      assert ProposalView.result(project, proposal) == {:error, :missing_objects}
    end

    test "hides a sensitive path that exists only on the parent side", %{
      owner: owner,
      project: project
    } do
      parent = node_with_snapshot(project, %{"keep.txt" => "same", ".env" => "plain-value"})
      result = snapshot_tree(project, %{"keep.txt" => "same"})
      proposal = meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result)

      assert {:ok, view} = ProposalView.result(project, proposal)
      assert view.hidden_count == 1
      assert view.files == []
      refute view.quarantined?
    end

    test "does not quarantine on a secret value behind a hidden path", %{
      owner: owner,
      project: project
    } do
      # Approved 4a-2 decision: paths are filtered and counted, while a secret
      # *value* in a visible file quarantines the whole result. This page renders
      # no content, so a value behind a hidden name cannot reach the browser.
      parent = node_with_snapshot(project, %{"notes.txt" => "one"})

      result =
        snapshot_tree(project, %{
          "notes.txt" => "one",
          ".env" => "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789\n"
        })

      proposal = meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result)

      assert {:ok, view} = ProposalView.result(project, proposal)
      refute view.quarantined?
      assert view.hidden_count == 1
      assert view.files == []
    end

    test "truncates the visible file list at the configured cap", %{
      owner: owner,
      project: project
    } do
      parent = node_with_snapshot(project, %{"a.txt" => "1"})
      result = snapshot_tree(project, %{"a.txt" => "2", "b.txt" => "2"})
      proposal = meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result)

      assert {:ok, view} = ProposalView.result(project, proposal, max_files: 1)
      assert view.truncated?
      assert length(view.files) == 1
      assert view.summary == %{added: 1, modified: 1, deleted: 0}
    end
  end

  describe "result/3 caching" do
    test "stores the rendered payload and serves later calls from it", %{
      owner: owner,
      project: project
    } do
      parent = node_with_snapshot(project, %{"a.txt" => "1"})
      result = snapshot_tree(project, %{"a.txt" => "2"})
      proposal = meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result)

      assert ProposalCache.size() == 0

      assert {:ok, view} = ProposalView.result(project, proposal)
      assert ProposalCache.size() == 1

      assert {:ok, ^view} = ProposalView.result(project, proposal)
      assert ProposalCache.size() == 1
    end

    test "serves a seeded payload without recomputing", %{owner: owner, project: project} do
      parent = node_with_snapshot(project, %{"a.txt" => "1"})
      result = snapshot_tree(project, %{"a.txt" => "2"})
      proposal = meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result)

      sentinel = %{
        quarantined?: false,
        truncated?: true,
        hidden_count: 7,
        summary: %{added: 0, modified: 0, deleted: 0},
        files: [%{path: "sentinel.txt", status: :added}]
      }

      assert {:ok, key} = ProposalView.result_cache_key(project, proposal)
      assert :ok = ProposalCache.put(key, sentinel)

      # A real render would return the a.txt diff, so this proves the second
      # call reads the cache instead of walking the store.
      assert {:ok, ^sentinel} = ProposalView.result(project, proposal)
    end

    test "does not cache errors", %{owner: owner, project: project} do
      parent = node_with_snapshot(project, %{"a.txt" => "a"})
      result = snapshot_tree(project, %{"a.txt" => "b"})
      bogus = String.duplicate("b", 40)

      missing =
        meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result, %{
          meld_commit_sha: bogus,
          result_tree_sha: bogus
        })

      assert ProposalView.result(project, missing) == {:error, :missing_objects}
      assert ProposalCache.size() == 0

      oversized_result =
        snapshot_tree(project, %{"large.txt" => String.duplicate("a", 70_000)})

      oversized =
        meld_proposal(
          project,
          owner,
          [parent, node_with_snapshot(project, %{})],
          oversized_result
        )

      assert ProposalView.result(project, oversized) == {:error, :too_large}
      assert ProposalCache.size() == 0
    end

    test "does not cache promotions", %{owner: owner, project: project} do
      node = node_with_snapshot(project, %{"a.txt" => "a"})
      proposal = promotion_proposal(project, owner, node)

      assert ProposalView.result(project, proposal) == :none
      assert ProposalCache.size() == 0
      assert ProposalView.result_cache_key(project, proposal) == :no_cache
    end

    test "a non-positive entry bound disables caching", %{owner: owner, project: project} do
      parent = node_with_snapshot(project, %{"a.txt" => "1"})
      result = snapshot_tree(project, %{"a.txt" => "2"})
      proposal = meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result)

      restore_env(:proposal_cache_entries)
      Application.put_env(:cadence_server, :proposal_cache_entries, 0)

      refute ProposalCache.enabled?()

      assert {:ok, view} = ProposalView.result(project, proposal)
      assert view.files == [%{path: "a.txt", status: :modified}]

      # `size/0` reports 0 whenever disabled, so read the table directly and
      # probe the exact key to prove `put/2` really was a no-op.
      assert {:ok, key} = ProposalView.result_cache_key(project, proposal)
      assert ProposalCache.get(key) == :miss
      assert :ets.info(:cadence_proposal_cache, :size) == 0
    end

    test "does not cache a parent-side overflow", %{owner: owner, project: project} do
      parent = node_with_snapshot(project, %{"large.txt" => String.duplicate("a", 70_000)})
      result = snapshot_tree(project, %{"small.txt" => "small"})
      proposal = meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result)

      assert ProposalView.result(project, proposal) == {:error, :too_large}

      assert {:ok, key} = ProposalView.result_cache_key(project, proposal)
      assert ProposalCache.get(key) == :miss
      assert ProposalCache.size() == 0
    end

    test "verify_resolution re-scans instead of trusting a cached payload", %{
      owner: owner,
      project: project
    } do
      parent = node_with_snapshot(project, %{"a.txt" => "1"})
      result = snapshot_tree(project, %{"a.txt" => "2"})
      proposal = meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result)
      incident = open_incident(project, proposal)

      sentinel = %{
        quarantined?: true,
        truncated?: false,
        hidden_count: 0,
        summary: %{added: 0, modified: 0, deleted: 0},
        files: []
      }

      assert {:ok, key} = ProposalView.result_cache_key(project, proposal)
      assert :ok = ProposalCache.put(key, sentinel)
      assert ProposalCache.get(key) == {:ok, sentinel}

      # A cache reader would report `:still_risky` from the sentinel; the
      # resolution path re-walks the real (clean) result instead.
      assert ProposalView.verify_resolution(incident) == :ok
    end

    test "evicts the oldest insertion when the bound is reached" do
      restore_env(:proposal_cache_entries)
      Application.put_env(:cadence_server, :proposal_cache_entries, 2)

      payload = %{quarantined?: false, files: []}

      ProposalCache.clear()
      assert :ok = ProposalCache.put(:first, payload)
      assert :ok = ProposalCache.put(:second, payload)
      assert :ok = ProposalCache.put(:third, payload)

      assert ProposalCache.size() == 2
      assert ProposalCache.get(:first) == :miss
      assert {:ok, ^payload} = ProposalCache.get(:second)
      assert {:ok, ^payload} = ProposalCache.get(:third)
    end

    test "the key includes the visible-file cap", %{owner: owner, project: project} do
      parent = node_with_snapshot(project, %{"a.txt" => "1"})
      result = snapshot_tree(project, %{"a.txt" => "2"})
      proposal = meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result)

      assert {:ok, default_key} = ProposalView.result_cache_key(project, proposal)
      assert {:ok, capped_key} = ProposalView.result_cache_key(project, proposal, max_files: 1)

      refute default_key == capped_key
    end

    test "the key includes the scan caps", %{owner: owner, project: project} do
      parent = node_with_snapshot(project, %{"a.txt" => "1"})
      result = snapshot_tree(project, %{"a.txt" => "2"})
      proposal = meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result)

      assert {:ok, default_key} = ProposalView.result_cache_key(project, proposal)

      restore_env(:scan_max_files)
      Application.put_env(:cadence_server, :scan_max_files, 999)

      assert {:ok, narrowed_key} = ProposalView.result_cache_key(project, proposal)

      refute default_key == narrowed_key
    end
  end

  describe "parents/1" do
    test "returns parents in parent_ids order and drops foreign nodes", %{
      owner: owner,
      project: project
    } do
      first = node_with_snapshot(project, %{"a.txt" => "a"})
      second = node_with_snapshot(project, %{"b.txt" => "b"})

      foreign_project = project(Ecto.UUID.generate())
      foreign = node_with_snapshot(foreign_project, %{"c.txt" => "c"})

      result = snapshot_tree(project, %{"a.txt" => "merged"})

      proposal =
        proposal(%{
          project_id: project.id,
          proposer_id: owner,
          kind: :meld,
          parent_ids: [second.id, first.id, foreign.id],
          result_tree_sha: result.tree,
          meld_commit_sha: result.commit
        })

      assert Enum.map(ProposalView.parents(proposal), & &1.id) == [second.id, first.id]
    end

    test "returns [] for a proposal without parents", %{owner: owner, project: project} do
      node = node_with_snapshot(project, %{"a.txt" => "a"})
      proposal = promotion_proposal(project, owner, node)

      assert ProposalView.parents(proposal) == []
    end
  end

  describe "target_node/1" do
    test "returns the promotion target and nil for melds", %{owner: owner, project: project} do
      node = node_with_snapshot(project, %{"a.txt" => "a"})
      promotion = promotion_proposal(project, owner, node)

      assert %{id: id} = ProposalView.target_node(promotion)
      assert id == node.id

      meld =
        meld_proposal(
          project,
          owner,
          [node, node_with_snapshot(project, %{})],
          snapshot_tree(project, %{"a.txt" => "b"})
        )

      assert ProposalView.target_node(meld) == nil
    end
  end

  describe "isolated?/1" do
    test "tracks open critical incidents", %{owner: owner, project: project} do
      parent = node_with_snapshot(project, %{"a.txt" => "a"})
      result = snapshot_tree(project, %{"a.txt" => "b"})
      proposal = meld_proposal(project, owner, [parent, node_with_snapshot(project, %{})], result)

      refute ProposalView.isolated?(proposal)

      incident =
        open_incident(project, proposal)

      assert ProposalView.isolated?(proposal)

      assert {:ok, _resolved} = Incidents.resolve(%{id: owner}, project.id, incident.id)
      refute ProposalView.isolated?(proposal)
    end
  end

  defp open_incident(project, proposal) do
    {:ok, incident} =
      Incidents.open(%{
        project_id: project.id,
        proposal_id: proposal.id,
        kind: :secret_detected,
        severity: :critical,
        title: "Secret detected in meld result",
        details: %{patterns: [:github_token]}
      })

    incident
  end

  # Restore a server config key exactly (unset stays unset), so a test that
  # narrows a cap cannot leak it into later tests.
  defp restore_env(key) do
    previous = Application.get_env(:cadence_server, key)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:cadence_server, key)
        value -> Application.put_env(:cadence_server, key, value)
      end
    end)
  end
end
