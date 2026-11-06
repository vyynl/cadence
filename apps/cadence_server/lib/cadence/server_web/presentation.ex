defmodule Cadence.ServerWeb.Presentation do
  @moduledoc """
  Pure formatting and badge-class helpers shared by the server-rendered
  surfaces (spec §7.2).

  The review hub, the member review page, the public proposal page, the project
  home, and the portfolio index use the same vocabulary for proposal status,
  incident severity, and file status. Keeping the class strings here means a
  new variant cannot drift between templates.

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
end
