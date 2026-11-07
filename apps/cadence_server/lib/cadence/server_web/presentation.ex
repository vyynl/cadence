defmodule Cadence.ServerWeb.Presentation do
  @moduledoc """
  Pure formatting and badge-class helpers shared by the server-rendered
  surfaces (spec §7.2).

  The review hub, the member review page, the public proposal page, the project
  home, and the action-run pages use the same vocabulary for proposal status,
  incident severity, file status, run status, and error reasons. The project
  home also labels a node's documentation state. Keeping the class strings here
  means a new variant cannot drift between templates.

  Nothing in this module touches Phoenix, Ecto, or the repository: every
  function is deterministic except `age/1`, which reads the current time.
  """

  @doc """
  Human title for a proposal kind.
  """
  @spec kind_title(atom() | nil) :: String.t()
  def kind_title(:meld), do: "Meld proposal"
  def kind_title(:promotion), do: "Promotion proposal"
  def kind_title(_kind), do: "Proposal"

  @doc """
  Renders a node's flags with its pin state, e.g. `"in-progress · pinned"`.
  """
  @spec format_flags([atom()], boolean()) :: String.t()
  def format_flags([], false), do: "no flags"
  def format_flags([], true), do: "pinned"

  def format_flags(flags, pinned) when is_list(flags) do
    text = Enum.map_join(flags, ", ", &Atom.to_string/1)
    if pinned, do: text <> " · pinned", else: text
  end

  @doc """
  Absolute timestamp used on proposal and node metadata.
  """
  @spec format_time(DateTime.t()) :: String.t()
  def format_time(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  @doc """
  Coarse relative age for review queues and incident panels.
  """
  @spec age(DateTime.t()) :: String.t()
  def age(%DateTime{} = created_at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), created_at, :second), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  @doc """
  Badge classes for a proposal status (`:pending`, `:approved`, `:rejected`).
  """
  @spec status_badge_class(atom() | nil) :: String.t()
  def status_badge_class(:pending), do: "badge status-badge status-pending"
  def status_badge_class(:approved), do: "badge status-badge status-approved"
  def status_badge_class(:rejected), do: "badge status-badge status-rejected"
  def status_badge_class(_status), do: "badge status-badge"

  @doc """
  Badge classes for an incident severity (`:critical`, `:high`).
  """
  @spec severity_badge_class(atom() | nil) :: String.t()
  def severity_badge_class(:critical), do: "badge severity-badge severity-critical"
  def severity_badge_class(:high), do: "badge severity-badge severity-high"
  def severity_badge_class(_severity), do: "badge severity-badge"

  @doc """
  Classes for a result file status (`:added`, `:modified`, `:deleted`).
  """
  @spec file_status_class(atom() | nil) :: String.t()
  def file_status_class(:added), do: "file-status file-status-added"
  def file_status_class(:modified), do: "file-status file-status-modified"
  def file_status_class(:deleted), do: "file-status file-status-deleted"
  def file_status_class(_status), do: "file-status"

  @doc """
  Human label for a node's documentation state (spec §9.4).

  `:current` means the generation was committed, `:pending` means a job is
  queued, deferred, or retrying, and `:skipped` means the commit is code-only.
  """
  @spec docs_state_label(atom() | nil) :: String.t()
  def docs_state_label(:current), do: "docs current"
  def docs_state_label(:pending), do: "docs pending"
  def docs_state_label(:skipped), do: "docs skipped"
  def docs_state_label(_state), do: "docs unknown"

  @doc """
  Badge classes for a node's documentation state (`:current`, `:pending`,
  `:skipped`).

  The modifiers reuse the status text tokens so the badge follows the light and
  dark palettes without introducing new hues.
  """
  @spec docs_badge_class(atom() | nil) :: String.t()
  def docs_badge_class(:current), do: "badge docs-badge docs-current"
  def docs_badge_class(:pending), do: "badge docs-badge docs-pending"
  def docs_badge_class(:skipped), do: "badge docs-badge docs-skipped"
  def docs_badge_class(_state), do: "badge docs-badge"

  @doc """
  Human label for an action run status (spec §8.3).
  """
  @spec run_status_label(atom() | nil) :: String.t()
  def run_status_label(:queued), do: "queued"
  def run_status_label(:running), do: "running"
  def run_status_label(:succeeded), do: "succeeded"
  def run_status_label(:failed), do: "failed"
  def run_status_label(:timed_out), do: "timed out"
  def run_status_label(:interrupted), do: "interrupted"
  def run_status_label(_status), do: "unknown"

  @doc """
  Badge classes for an action run status.

  Pending/rejected reuse the AA status text tokens: `queued`/`running` read as
  pending, `succeeded` as approved, and every failure as rejected.
  """
  @spec run_status_class(atom() | nil) :: String.t()
  def run_status_class(:queued), do: "badge status-badge status-pending"
  def run_status_class(:running), do: "badge status-badge status-pending"
  def run_status_class(:succeeded), do: "badge status-badge status-approved"
  def run_status_class(:failed), do: "badge status-badge status-rejected"
  def run_status_class(:timed_out), do: "badge status-badge status-rejected"
  def run_status_class(:interrupted), do: "badge status-badge status-rejected"
  def run_status_class(_status), do: "badge status-badge"

  @doc """
  User-facing explanation for a closed `action_runs.error_reason` value.

  Unknown reasons collapse to a generic failure sentence so a future reason
  cannot leak an internal term to the page.
  """
  @spec run_error_label(String.t() | nil) :: String.t() | nil
  def run_error_label(nil), do: nil
  def run_error_label("quarantined"), do: "The snapshot is quarantined, so the run was refused."
  def run_error_label("staging_failed"), do: "The snapshot could not be staged."
  def run_error_label("no_image"), do: "No image: set a project image or add a root Dockerfile."
  def run_error_label("build_failed"), do: "The image build failed."
  def run_error_label("create_failed"), do: "The container could not be created."
  def run_error_label("docker_unavailable"), do: "The Docker daemon is unavailable."
  def run_error_label("timeout"), do: "The action timed out and was stopped."
  def run_error_label("interrupted"), do: "The run was interrupted before it finished."
  def run_error_label(_reason), do: "The action failed to run."

  @doc """
  Wall-clock duration between a run's start and finish, or `nil` when the run
  has not finished. Kept coarse because the value is informational.
  """
  @spec run_duration(DateTime.t() | nil, DateTime.t() | nil) :: String.t() | nil
  def run_duration(%DateTime{} = started_at, %DateTime{} = finished_at) do
    finished_at
    |> DateTime.diff(started_at, :millisecond)
    |> max(0)
    |> format_duration()
  end

  def run_duration(_started_at, _finished_at), do: nil

  @doc """
  Render captured terminal output as plain text.

  Container output arrives with ANSI CSI/OSC sequences, cursor control, CRLF
  line endings, and possibly invalid UTF-8. This strips escape sequences,
  remaining C0/C1 control bytes, and Unicode bidi overrides (so a log cannot
  spoof line direction), normalizes line endings, replaces invalid bytes, and
  leaves the result safe to interpolate inside a `<pre>` (HEEx escapes HTML; the
  caller never uses `raw/1`).
  """
  @spec terminal_text(binary() | nil) :: String.t()
  def terminal_text(nil), do: ""

  def terminal_text(content) when is_binary(content) do
    content
    |> String.replace_invalid("�")
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(~r/\e\][^\x07\e]*(?:\x07|\e\\)/, "")
    |> String.replace(~r{\e\[[0-?]*[ -/]*[@-~]}, "")
    |> String.replace(~r{\e[@-_]}, "")
    |> String.replace(~r{[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]}, "")
    |> String.replace(~r/[\x{0080}-\x{009F}]/u, "")
    |> String.replace(~r/[\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u, "")
  end

  def terminal_text(_content), do: ""

  defp format_duration(ms) when ms < 3_600_000 do
    # Truncate to 0.1s so a value just under a minute never renders as "60.0s".
    seconds = Float.floor(ms / 100) / 10

    if seconds < 60.0 do
      "#{seconds}s"
    else
      whole = div(ms, 1_000)
      "#{div(whole, 60)}m #{rem(whole, 60)}s"
    end
  end

  defp format_duration(ms) do
    minutes = div(ms, 60_000)
    "#{div(minutes, 60)}h #{rem(minutes, 60)}m"
  end
end
