defmodule Cadence.ServerWeb.PresentationTest do
  use ExUnit.Case, async: true

  alias Cadence.ServerWeb.Presentation

  describe "kind_title/1" do
    test "titles each known kind" do
      assert Presentation.kind_title(:meld) == "Meld proposal"
      assert Presentation.kind_title(:promotion) == "Promotion proposal"
    end

    test "falls back for unknown and nil kinds" do
      assert Presentation.kind_title(:unknown) == "Proposal"
      assert Presentation.kind_title(nil) == "Proposal"
    end
  end

  describe "format_flags/2" do
    test "renders the no-flag cases" do
      assert Presentation.format_flags([], false) == "no flags"
      assert Presentation.format_flags([], true) == "pinned"
    end

    test "renders one and several flags in order" do
      assert Presentation.format_flags([:functioning], false) == "functioning"
      assert Presentation.format_flags([:broken, :sandbox], false) == "broken, sandbox"
    end

    test "appends the pin when pinned" do
      assert Presentation.format_flags([:"in-progress"], true) == "in-progress · pinned"
    end
  end

  describe "format_time/1" do
    test "renders a UTC timestamp" do
      assert Presentation.format_time(~U[2026-11-06 09:05:04Z]) == "2026-11-06 09:05:04 UTC"
    end
  end

  describe "age/1" do
    defp seconds_ago(seconds) do
      DateTime.add(DateTime.utc_now(), -seconds, :second)
    end

    test "nothing newer than a minute reads as just now" do
      assert Presentation.age(seconds_ago(30)) == "just now"
    end

    test "minutes, hours, and days" do
      assert Presentation.age(seconds_ago(120)) == "2m ago"
      assert Presentation.age(seconds_ago(7_200)) == "2h ago"
      assert Presentation.age(seconds_ago(180_000)) == "2d ago"
    end

    test "a timestamp in the future does not go negative" do
      assert Presentation.age(DateTime.add(DateTime.utc_now(), 60, :second)) == "just now"
    end
  end

  describe "status_badge_class/1" do
    test "returns the semantic status variant" do
      assert Presentation.status_badge_class(:pending) == "badge status-badge status-pending"

      assert Presentation.status_badge_class(:approved) ==
               "badge status-badge status-approved"

      assert Presentation.status_badge_class(:rejected) ==
               "badge status-badge status-rejected"
    end

    test "falls back to the neutral badge" do
      assert Presentation.status_badge_class(:other) == "badge status-badge"
      assert Presentation.status_badge_class(nil) == "badge status-badge"
    end
  end

  describe "severity_badge_class/1" do
    test "returns a distinct variant per severity" do
      assert Presentation.severity_badge_class(:critical) ==
               "badge severity-badge severity-critical"

      assert Presentation.severity_badge_class(:high) == "badge severity-badge severity-high"
    end

    test "falls back to the neutral badge" do
      assert Presentation.severity_badge_class(:low) == "badge severity-badge"
    end
  end

  describe "file_status_class/1" do
    test "returns a distinct variant per file status" do
      assert Presentation.file_status_class(:added) == "file-status file-status-added"
      assert Presentation.file_status_class(:modified) == "file-status file-status-modified"
      assert Presentation.file_status_class(:deleted) == "file-status file-status-deleted"
    end

    test "falls back to the neutral file status" do
      assert Presentation.file_status_class(:renamed) == "file-status"
    end
  end

  describe "docs_state_label/1" do
    test "labels each known docs state" do
      assert Presentation.docs_state_label(:current) == "docs current"
      assert Presentation.docs_state_label(:pending) == "docs pending"
      assert Presentation.docs_state_label(:skipped) == "docs skipped"
    end

    test "falls back for an unknown or nil state" do
      assert Presentation.docs_state_label(:other) == "docs unknown"
      assert Presentation.docs_state_label(nil) == "docs unknown"
    end
  end

  describe "docs_badge_class/1" do
    test "returns a distinct variant per docs state" do
      assert Presentation.docs_badge_class(:current) == "badge docs-badge docs-current"
      assert Presentation.docs_badge_class(:pending) == "badge docs-badge docs-pending"
      assert Presentation.docs_badge_class(:skipped) == "badge docs-badge docs-skipped"
    end

    test "falls back to the neutral docs badge" do
      assert Presentation.docs_badge_class(:other) == "badge docs-badge"
      assert Presentation.docs_badge_class(nil) == "badge docs-badge"
    end
  end
end
