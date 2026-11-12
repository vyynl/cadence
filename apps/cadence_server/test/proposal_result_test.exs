defmodule Cadence.ServerWeb.Components.ProposalResultTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Cadence.ServerWeb.Components.ProposalResult
  alias Cadence.ServerWeb.Presentation

  @public_stays_visible "Status and timestamps stay visible."
  @review_can_act "Resolve it before deciding, or reject and re-propose."

  defp render_block(result, audience, opts \\ []) do
    render_component(&ProposalResult.result/1, %{
      result: result,
      audience: audience,
      project_slug: "demo",
      target_node: Keyword.get(opts, :target_node)
    })
  end

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        quarantined?: false,
        truncated?: false,
        hidden_count: 0,
        summary: %{added: 1, modified: 1, deleted: 1},
        files: [
          %{path: "new.txt", status: :added},
          %{path: "edit.txt", status: :modified},
          %{path: "gone.txt", status: :deleted}
        ]
      },
      overrides
    )
  end

  describe "isolated results" do
    test "the public sentinel says what stays visible" do
      html = render_block(:isolated, :public)

      assert html =~ "Result hidden for review"

      assert html =~
               "The meld result is hidden while a critical incident is open. #{@public_stays_visible}"

      refute html =~ @review_can_act
      refute html =~ "compared with the first parent"
    end

    test "the review sentinel says how to unblock" do
      html = render_block(:isolated, :review)

      assert html =~ "Result hidden for review"

      assert html =~
               "The meld result is hidden while a critical incident is open. #{@review_can_act}"

      refute html =~ @public_stays_visible
      refute html =~ "compared with the first parent"
    end

    test "the two isolation sentinels are distinct" do
      refute render_block(:isolated, :public) == render_block(:isolated, :review)
    end
  end

  describe "promotion results" do
    test "renders the note and a link to the target node" do
      html = render_block(:none, :public, target_node: %{id: "node-1"})

      assert html =~ "Promotion proposals have no meld result."
      assert html =~ "View the target node"
      assert html =~ ~s(href="/p/demo/n/node-1")
      refute html =~ "The target node is not available."
    end

    test "notes a missing target node" do
      html = render_block(:none, :review)

      assert html =~ "Promotion proposals have no meld result."
      assert html =~ "The target node is not available."
      refute html =~ "View the target node"
    end
  end

  describe "quarantined results" do
    test "the public sentinel adds what stays visible" do
      html = render_block({:ok, payload(%{quarantined?: true})}, :public)

      assert html =~ "Result hidden for review"

      assert html =~
               "The meld result is hidden while it is reviewed for sensitive content. #{@public_stays_visible}"

      refute html =~ "new.txt"
      refute html =~ "compared with the first parent"
    end

    test "the review sentinel stays short" do
      html = render_block({:ok, payload(%{quarantined?: true})}, :review)

      assert html =~ "Result hidden for review"
      assert html =~ "The meld result is hidden while it is reviewed for sensitive content."
      refute html =~ @public_stays_visible
      refute html =~ "new.txt"
      refute html =~ "compared with the first parent"
    end
  end

  describe "readable results" do
    test "renders the summary line and one row per file with its status class" do
      html = render_block({:ok, payload()}, :public)

      assert html =~ "<h2>Result</h2>"
      assert html =~ ~r/1 added · 1 modified · 1 deleted\s+— compared with the first parent\./

      assert html =~ ~s(class="#{Presentation.file_status_class(:added)}")
      assert html =~ ~s(class="#{Presentation.file_status_class(:modified)}")
      assert html =~ ~s(class="#{Presentation.file_status_class(:deleted)}")

      assert html =~ "new.txt"
      assert html =~ "edit.txt"
      assert html =~ "gone.txt"
      refute html =~ "hidden for security"
      refute html =~ "The file list is truncated."
    end

    test "pluralises the hidden count" do
      singular = render_block({:ok, payload(%{hidden_count: 1})}, :review)
      plural = render_block({:ok, payload(%{hidden_count: 2})}, :review)

      assert singular =~ "1 file hidden for security."
      refute singular =~ "files hidden for security."

      assert plural =~ "2 files hidden for security."
      refute plural =~ "1 file hidden for security."
    end

    test "notes a truncated file list" do
      html = render_block({:ok, payload(%{truncated?: true})}, :public)

      assert html =~ "The file list is truncated."
    end

    test "notes an empty file list" do
      html = render_block({:ok, payload(%{files: []})}, :public)

      assert html =~ "No file changes against the first parent."
      refute html =~ "file-tree"
      refute html =~ "new.txt"
    end
  end

  describe "error results" do
    test "renders a missing result note" do
      assert render_block({:error, :missing_objects}, :public) =~
               "The meld result is not available yet."
    end

    test "renders the too-large note" do
      assert render_block({:error, :too_large}, :public) =~
               "The result is too large to review in the browser."
    end

    test "renders any other error as a missing result" do
      assert render_block({:error, :something_else}, :review) =~
               "The meld result is not available yet."
    end

    test "an unexpected result shape degrades to the generic note" do
      html = render_block(%{}, :public)

      assert html =~ "<h2>Result</h2>"
      assert html =~ "The meld result is not available yet."
      refute html =~ "compared with the first parent"
    end
  end

  describe "audience identity" do
    test "both audiences render the same bytes for a readable payload" do
      payloads = [
        payload(),
        payload(%{hidden_count: 2, truncated?: true}),
        payload(%{files: []})
      ]

      for readable <- payloads do
        assert render_block({:ok, readable}, :public) == render_block({:ok, readable}, :review)
      end
    end
  end
end
