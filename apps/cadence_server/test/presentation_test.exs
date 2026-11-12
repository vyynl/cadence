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

  describe "run_status_label/1" do
    test "labels every run status" do
      assert Presentation.run_status_label(:queued) == "queued"
      assert Presentation.run_status_label(:running) == "running"
      assert Presentation.run_status_label(:succeeded) == "succeeded"
      assert Presentation.run_status_label(:failed) == "failed"
      assert Presentation.run_status_label(:timed_out) == "timed out"
      assert Presentation.run_status_label(:interrupted) == "interrupted"
    end

    test "falls back for an unknown or nil status" do
      assert Presentation.run_status_label(:other) == "unknown"
      assert Presentation.run_status_label(nil) == "unknown"
    end
  end

  describe "run_status_class/1" do
    test "maps statuses onto the semantic badge variants" do
      assert Presentation.run_status_class(:queued) == "badge status-badge status-pending"
      assert Presentation.run_status_class(:running) == "badge status-badge status-pending"
      assert Presentation.run_status_class(:succeeded) == "badge status-badge status-approved"
      assert Presentation.run_status_class(:failed) == "badge status-badge status-rejected"
      assert Presentation.run_status_class(:timed_out) == "badge status-badge status-rejected"
      assert Presentation.run_status_class(:interrupted) == "badge status-badge status-rejected"
    end

    test "falls back to the neutral badge" do
      assert Presentation.run_status_class(:other) == "badge status-badge"
      assert Presentation.run_status_class(nil) == "badge status-badge"
    end
  end

  describe "run_error_label/1" do
    test "explains each closed run error reason" do
      assert Presentation.run_error_label("quarantined") =~ "quarantined"
      assert Presentation.run_error_label("no_image") =~ "No image"
      assert Presentation.run_error_label("build_failed") =~ "build"
      assert Presentation.run_error_label("timeout") =~ "timed out"
    end

    test "keeps nil nil and collapses unknown reasons" do
      assert Presentation.run_error_label(nil) == nil
      assert Presentation.run_error_label("something_new") == "The action failed to run."
    end
  end

  describe "import_author/1" do
    test "returns the trimmed author for a git import" do
      metadata = %{"import" => %{"source" => "git", "author" => "  Ada Lovelace  "}}

      assert Presentation.import_author(metadata) == "Ada Lovelace"
    end

    test "returns nil for missing, malformed, or non-git metadata" do
      assert Presentation.import_author(nil) == nil
      assert Presentation.import_author(%{}) == nil
      assert Presentation.import_author(%{"import" => "nope"}) == nil

      assert Presentation.import_author(%{
               "import" => %{"source" => "svn", "author" => "Ada"}
             }) == nil

      assert Presentation.import_author(%{"import" => %{"author" => "Ada"}}) == nil
      assert Presentation.import_author(:not_a_map) == nil
    end

    test "returns nil for a blank or non-binary author" do
      assert Presentation.import_author(%{
               "import" => %{"source" => "git", "author" => "   "}
             }) == nil

      assert Presentation.import_author(%{
               "import" => %{"source" => "git", "author" => 123}
             }) == nil
    end
  end

  describe "import_provenance/2" do
    setup do
      %{
        metadata: %{
          "import" => %{
            "source" => "git",
            "author" => "  Ada Lovelace ",
            "author_email" => " ada@example.com "
          }
        }
      }
    end

    test "a manager sees the author and the email", %{metadata: metadata} do
      assert Presentation.import_provenance(metadata, true) == %{
               author: "Ada Lovelace",
               email: "ada@example.com"
             }
    end

    test "false or nil hides the email but keeps the author", %{metadata: metadata} do
      assert Presentation.import_provenance(metadata, false) == %{
               author: "Ada Lovelace",
               email: nil
             }

      assert Presentation.import_provenance(metadata, nil) == %{
               author: "Ada Lovelace",
               email: nil
             }
    end

    test "a blank email is nil even for a manager", %{metadata: metadata} do
      metadata = put_in(metadata, ["import", "author_email"], "  ")

      assert Presentation.import_provenance(metadata, true) == %{
               author: "Ada Lovelace",
               email: nil
             }
    end

    test "non-imported and malformed metadata yield nil" do
      assert Presentation.import_provenance(nil, true) == nil
      assert Presentation.import_provenance(%{"import" => %{"author" => "Ada"}}, true) == nil
      assert Presentation.import_provenance(%{"import" => "git"}, true) == nil
    end
  end

  describe "page_number/1" do
    test "parses a positive integer page" do
      assert Presentation.page_number("3") == 3
      assert Presentation.page_number("+2") == 2
    end

    test "falls back to page 1 for anything else" do
      assert Presentation.page_number(nil) == 1
      assert Presentation.page_number("") == 1
      assert Presentation.page_number("0") == 1
      assert Presentation.page_number("-3") == 1
      assert Presentation.page_number("2x") == 1
      assert Presentation.page_number("nope") == 1
      assert Presentation.page_number(2) == 1
    end
  end

  describe "page_for/2" do
    test "derives the page from the offset that was read" do
      assert Presentation.page_for(0, 50) == 1
      assert Presentation.page_for(50, 50) == 2
      assert Presentation.page_for(100, 50) == 3
    end

    test "reports the clamped window honestly" do
      assert Presentation.page_for(1_000_000, 50) == 20_001
    end
  end

  describe "run_duration/2" do
    test "formats sub-minute, minute, and hour durations" do
      started = ~U[2026-11-06 09:00:00.000Z]

      assert Presentation.run_duration(started, DateTime.add(started, 500, :millisecond)) ==
               "0.5s"

      assert Presentation.run_duration(started, DateTime.add(started, 65, :second)) == "1m 5s"
      assert Presentation.run_duration(started, DateTime.add(started, 3_720, :second)) == "1h 2m"
    end

    test "returns nil until the run has started and finished" do
      started = ~U[2026-11-06 09:00:00.000Z]
      assert Presentation.run_duration(nil, started) == nil
      assert Presentation.run_duration(started, nil) == nil
    end

    test "truncates instead of rounding across the minute boundary" do
      started = ~U[2026-11-06 09:00:00.000Z]
      finished = DateTime.add(started, 59_990, :millisecond)
      assert Presentation.run_duration(started, finished) == "59.9s"
    end
  end

  describe "terminal_text/1" do
    test "strips ANSI CSI and OSC sequences" do
      assert Presentation.terminal_text("\e[31mred\e[0m\n") == "red\n"
      assert Presentation.terminal_text("\e]0;title\ahello") == "hello"
      assert Presentation.terminal_text("\e[2K\e[1;1Hprogress") == "progress"
    end

    test "normalizes CRLF and lone carriage returns" do
      assert Presentation.terminal_text("a\r\nb\rc") == "a\nb\nc"
    end

    test "removes NUL and remaining control bytes but keeps newlines and tabs" do
      assert Presentation.terminal_text("a\x00b\x07c\td\ne") == "abc\td\ne"
    end

    test "removes C1 controls and bidi overrides" do
      assert Presentation.terminal_text("a\u0085b\u202Ec\u2066d") == "abcd"
    end

    test "replaces invalid UTF-8 instead of raising" do
      text = Presentation.terminal_text(<<0xFF, 0xFE, "ok">>)

      assert String.valid?(text)
      assert text =~ "ok"
      assert text =~ "�"
    end

    test "leaves HTML for HEEx to escape" do
      assert Presentation.terminal_text("<script>alert(1)</script>") ==
               "<script>alert(1)</script>"
    end

    test "handles nil and non-binary input" do
      assert Presentation.terminal_text(nil) == ""
      assert Presentation.terminal_text(:not_a_log) == ""
    end
  end
end
