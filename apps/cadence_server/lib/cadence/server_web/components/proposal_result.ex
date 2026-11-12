defmodule Cadence.ServerWeb.Components.ProposalResult do
  @moduledoc """
  File-level result block shared by the public proposal page and the member
  review page (spec §7.6).

  The component owns everything inside `<section class="proposal-result">`
  except the wrapper itself and the review page's integrity notice. Result
  *paths and statuses* only — never file content — so both surfaces render one
  implementation and cannot drift.

  ## Contract

    * `result` — one of:
      * `:none` — a promotion proposal has no meld result; `target_node` is
        rendered as a link when present;
      * `:isolated` — an open critical incident hides the result. The caller
        checks `ProposalView.isolated?/1` before spending the result walks and
        maps it to this value;
      * `{:ok, payload}` — a readable result with `quarantined?: boolean`,
        `files: [%{path: binary, status: atom}]`, `hidden_count:
        non_neg_integer`, `truncated?: boolean`, and `summary: %{added: n,
        modified: n, deleted: n}`;
      * `{:error, reason}` — `:missing_objects`, `:too_large`, or any other
        reason; all render as a note.
    * `audience` — `:public | :review`, selecting the isolation and quarantine
      sentinel copy. The public page cannot act on the proposal, so its sentinel
      says what stays visible; the review page can resolve the incident or
      reject and re-propose, so its sentinel says how to unblock.
    * `project_slug` — used for the promotion target link.
    * `target_node` — the promotion target (a map or `Node` carrying `:id`) or
      `nil`; read only for `:none`.

  The surrounding `<section>`, the review-only integrity notice, and the public
  page's "Approval is not available" callout stay with the callers.
  """

  use Cadence.ServerWeb, :html

  alias Cadence.ServerWeb.Components.Repo
  alias Cadence.ServerWeb.Presentation

  # The two sentinels differ by audience on purpose. An anonymous reader of the
  # public page has no decision controls, so the notice tells them what remains
  # visible; a reviewer can act, so the notice tells them how to unblock the
  # result. The quarantine copy follows the same rule where the review decision
  # panel is rendered: its blocked-reason note carries the action copy, so this
  # sentinel stays shorter (viewers and decided proposals see no action note).
  @stays_visible "Status and timestamps stay visible."
  @can_act "Resolve it before deciding, or reject and re-propose."

  attr(:result, :any,
    required: true,
    doc: "`:none | :isolated | {:ok, payload} | {:error, reason}`"
  )

  attr(:audience, :atom,
    required: true,
    values: [:public, :review],
    doc: "selects the isolation and quarantine sentinel copy"
  )

  attr(:project_slug, :string, required: true)

  attr(:target_node, :any,
    default: nil,
    doc: "promotion target carrying `:id`; only read for `:none`"
  )

  def result(assigns) do
    ~H"""
    <h2>Result</h2>

    <%= case @result do %>
      <% :isolated -> %>
        <Repo.quarantine
          eyebrow="Protected proposal"
          title="Result hidden for review"
          body={isolation_body(@audience)}
        />
      <% :none -> %>
        <p class="note">Promotion proposals have no meld result.</p>
        <p :if={@target_node}>
          <a class="button-link" href={~p"/p/#{@project_slug}/n/#{@target_node.id}"}>View the target node</a>
        </p>
        <p :if={is_nil(@target_node)} class="note">The target node is not available.</p>
      <% {:ok, result} -> %>
        <%= if result.quarantined? do %>
          <Repo.quarantine
            eyebrow="Protected proposal"
            title="Result hidden for review"
            body={quarantine_body(@audience)}
          />
        <% else %>
          <p class="note">
            {result.summary.added} added · {result.summary.modified} modified · {result.summary.deleted} deleted
            — compared with the first parent.
          </p>

          <ul :if={result.files != []} class="file-tree">
            <li :for={file <- result.files}>
              <div class="file-row">
                <span class={Presentation.file_status_class(file.status)}>
                  {file.status}
                </span>
                <span class="file-name">{file.path}</span>
              </div>
            </li>
          </ul>

          <p :if={result.files == []} class="note">No file changes against the first parent.</p>

          <p :if={result.hidden_count > 0} class="note">
            {result.hidden_count} {if result.hidden_count == 1, do: "file", else: "files"} hidden for security.
          </p>

          <p :if={result.truncated?} class="note">The file list is truncated.</p>
        <% end %>
      <% {:error, :missing_objects} -> %>
        <p class="note">The meld result is not available yet.</p>
      <% {:error, :too_large} -> %>
        <p class="note">The result is too large to review in the browser.</p>
      <% {:error, _reason} -> %>
        <p class="note">The meld result is not available yet.</p>
      <% _other -> %>
        <% # Deliberate fail-closed guard: an unexpected @result shape degrades to %>
        <% # the generic note instead of raising a 500 on the public page. %>
        <p class="note">The meld result is not available yet.</p>
    <% end %>
    """
  end

  defp isolation_body(:public),
    do:
      "The meld result is hidden while a critical incident is open. " <>
        @stays_visible

  defp isolation_body(:review),
    do: "The meld result is hidden while a critical incident is open. " <> @can_act

  defp quarantine_body(:public),
    do:
      "The meld result is hidden while it is reviewed for sensitive content. " <>
        @stays_visible

  defp quarantine_body(:review),
    do: "The meld result is hidden while it is reviewed for sensitive content."
end
