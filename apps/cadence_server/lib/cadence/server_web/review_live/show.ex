defmodule Cadence.ServerWeb.ReviewLive.Show do
  @moduledoc """
  Member-only review page for one proposal (spec §6.6, §6.7, §7.2).

  Shows the decision state, the proposer/reviewer identities (members only —
  the public `/proposals/:token` page never renders identities), the parents or
  promotion target, and the same file-level first-parent result as the public
  page, plus an integrity notice when the stored result cannot be verified.

  Decisions go through `Cadence.Server.Proposals`, never through this module:
  the LiveView re-checks `can_decide?/1` on every event (Iron Law 10) and maps
  the context's errors to flashes. Nothing renders file content and there is no
  raw toggle; result content stays path-only.

  Authorization runs in `handle_params/3` (a refused visitor must be redirected)
  while the review payload is loaded with `assign_async/3`, so the expiring
  work — two capped blob walks and the integrity walk — never runs in `mount/3`.

  ## Freshness

  The payload (including `isolated?` and the result diff) is recomputed on every
  `handle_params` and after every decision; nothing is cached on the proposal
  row. It is not pushed on external change: an incident opened elsewhere while
  the page is open does not reach this socket (there is no incident broadcast),
  so the Approve control can look enabled until the next load. The decision
  itself re-reads the membership and the context re-checks the incident, so a
  stale click still fails closed with `:blocked`/`:forbidden`.
  """

  use Cadence.ServerWeb, :live_view

  alias Cadence.Server.{Accounts, Authorization, ProposalView, Proposals, PublicContent}
  alias Cadence.ServerWeb.Components.Repo
  alias Cadence.ServerWeb.ReviewAccess

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Review",
       project: nil,
       proposal_id: nil,
       not_found: false,
       can_decide?: false,
       can_manage?: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case ReviewAccess.authorize(socket.assigns[:current_user], params["slug"]) do
      {:ok, project, membership} ->
        socket =
          assign(socket,
            page_title: "Review · #{project.name}",
            project: project,
            proposal_id: params["proposal_id"],
            not_found: false,
            can_decide?: Authorization.can_decide?(membership),
            can_manage?: Authorization.can_manage?(membership)
          )

        {:noreply, load_review(socket)}

      {:error, :forbidden} ->
        # `push_navigate/2` accepts only :to/:replace — a `flash:` option is
        # silently dropped. Put the flash on the socket so the live_redirect
        # payload carries it.
        {:noreply,
         socket
         |> put_flash(:error, "Only project members can review proposals.")
         |> push_navigate(to: ~p"/p/#{params["slug"]}")}

      {:error, :not_found} ->
        {:noreply,
         assign(socket,
           page_title: "Project not found",
           project: nil,
           not_found: true,
           can_decide?: false,
           can_manage?: false
         )}
    end
  end

  @impl true
  def handle_event("approve", _params, socket), do: decide(socket, :approved)

  def handle_event("reject", _params, socket), do: decide(socket, :rejected)

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <article>
      <%= if @not_found do %>
        <p class="eyebrow">404</p>
        <h1>Project not found</h1>
        <p class="note">There is no project at this address.</p>
        <p><a href="/">Back to Cadence</a></p>
      <% else %>
        <p class="eyebrow">
          <a href={~p"/p/#{@project.slug}/reviews"}>Reviews</a>
          <span class="note">/ {@project.name}</span>
        </p>

        <.async_result :let={review} assign={@review}>
          <:loading>
            <p class="note">Loading the proposal…</p>
          </:loading>

          <:failed :let={reason}>
            <h1>{if reason == {:error, :not_found}, do: "Proposal not found", else: "Proposal unavailable"}</h1>

            <p :if={reason == {:error, :not_found}} class="note">
              This project has no proposal with that address.
            </p>

            <p :if={reason != {:error, :not_found}} class="note">
              The proposal could not be loaded.
            </p>

            <p><a href={~p"/p/#{@project.slug}/reviews"}>Back to reviews</a></p>
          </:failed>

          <header class="project-header">
            <p class="eyebrow">Proposal</p>
            <h1>{kind_title(review.proposal.kind)}</h1>

            <p class="node-meta">
              <span class="flag-badge">{review.proposal.status}</span>
              <span :if={review.proposal.created_at}>
                opened
                <time datetime={DateTime.to_iso8601(review.proposal.created_at)}>
                  {format_time(review.proposal.created_at)}
                </time>
              </span>
              <span :if={review.proposal.decided_at}>
                decided
                <time datetime={DateTime.to_iso8601(review.proposal.decided_at)}>
                  {format_time(review.proposal.decided_at)}
                </time>
              </span>
            </p>

            <p class="node-meta">
              <span>Proposed by {identity(review.proposer, @can_manage?)}</span>
              <span :if={review.reviewer}>· Reviewed by {identity(review.reviewer, @can_manage?)}</span>
            </p>

            <p class="note">
              <a href={~p"/proposals/#{review.proposal.token}"}>Public read-only link</a>
            </p>
          </header>

          <section class="proposal-parents">
            <h2>Parents</h2>

            <ul :if={review.parents != []} class="file-tree">
              <li :for={parent <- review.parents}>
                <a class="file-row" href={~p"/p/#{@project.slug}/n/#{parent.id}"}>
                  <span class="file-kind">node</span>
                  <span class="file-name">{redact_message(parent.message) || "(no message)"}</span>
                </a>
                <p class="node-meta">
                  <span class="flag-badge">{format_flags(parent.flags, parent.pinned)}</span>
                  <code>{String.slice(parent.git_commit_sha, 0, 12)}</code>
                </p>
              </li>
            </ul>

            <p :if={review.parents == []} class="note">No parent nodes are available.</p>
          </section>

          <section class="proposal-result">
            <h2>Result</h2>

            <%= cond do %>
              <% review.isolated? -> %>
                <Repo.quarantine
                  eyebrow="Protected proposal"
                  title="Result hidden for review"
                  body="The meld result is hidden while a critical incident is open. Resolve it before deciding, or reject and re-propose."
                />
              <% review.result == :none -> %>
                <p class="note">Promotion proposals have no meld result.</p>
                <p :if={review.target_node}>
                  <a href={~p"/p/#{@project.slug}/n/#{review.target_node.id}"}>
                    View the target node
                  </a>
                </p>
                <p :if={is_nil(review.target_node)} class="note">The target node is not available.</p>
              <% true -> %>
                <%= case review.result do %>
                  <% {:ok, result} -> %>
                    <%= if result.quarantined? do %>
                      <Repo.quarantine
                        eyebrow="Protected proposal"
                        title="Result hidden for review"
                        body="The meld result is hidden while it is reviewed for sensitive content."
                      />
                    <% else %>
                      <p class="note">
                        {result.summary.added} added · {result.summary.modified} modified · {result.summary.deleted} deleted
                        — compared with the first parent.
                      </p>

                      <ul :if={result.files != []} class="file-tree">
                        <li :for={file <- result.files}>
                          <div class="file-row">
                            <span class="file-kind">{file.status}</span>
                            <span class="file-name">{file.path}</span>
                          </div>
                        </li>
                      </ul>

                      <p :if={result.files == []} class="note">
                        No file changes against the first parent.
                      </p>

                      <p :if={result.hidden_count > 0} class="note">
                        {result.hidden_count} {if result.hidden_count == 1, do: "file", else: "files"} hidden for security.
                      </p>

                      <p :if={result.truncated?} class="note">The file list is truncated.</p>
                    <% end %>
                  <% {:error, :missing_objects} -> %>
                    <p class="note">The meld result is not available yet.</p>
                  <% {:error, :too_large} -> %>
                    <p class="note">The result is too large to review in the browser.</p>
                  <% _other -> %>
                    <p class="note">The meld result is not available yet.</p>
                <% end %>
            <% end %>

            <p :if={review.integrity != :ok} class="note">
              The stored result could not be verified ({integrity_label(review.integrity)}), so it cannot be approved.
            </p>
          </section>

          <section :if={@can_decide? and review.proposal.status == :pending} class="admin-controls">
            <h2>Decision</h2>

            <%= if approvable?(review) do %>
              <button type="button" class="admin-button" phx-click="approve" phx-disable-with="Deciding…">
                Approve
              </button>
            <% else %>
              <p class="note">{blocked_reason(review)}</p>
            <% end %>

            <button type="button" class="admin-button" phx-click="reject" phx-disable-with="Deciding…">
              Reject
            </button>
          </section>

          <section :if={review.proposal.status != :pending} class="proposal-result">
            <h2>Decision</h2>
            <p class="note">
              This proposal was {review.proposal.status}. Only pending proposals can be decided.
            </p>
            <p :if={review.result_node}>
              <a href={~p"/p/#{@project.slug}/n/#{review.result_node.id}"}>
                View the {if review.proposal.kind == :meld, do: "meld", else: "promoted"} node
              </a>
            </p>
          </section>
        </.async_result>
      <% end %>
    </article>
    """
  end

  defp load_review(socket) do
    project = socket.assigns.project
    proposal_id = socket.assigns.proposal_id
    user_id = socket.assigns.current_user.id

    assign_async(socket, :review, fn -> load_payload(project, proposal_id, user_id) end)
  end

  defp load_payload(project, proposal_id, user_id) do
    case Proposals.get(%{id: user_id}, project.id, proposal_id) do
      {:ok, proposal} -> {:ok, %{review: review(project, proposal)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp review(project, proposal) do
    identities =
      Accounts.users_by_ids(Enum.reject([proposal.proposer_id, proposal.reviewer_id], &is_nil/1))

    %{
      proposal: proposal,
      proposer: Map.get(identities, proposal.proposer_id),
      reviewer: Map.get(identities, proposal.reviewer_id),
      parents: ProposalView.parents(proposal),
      target_node: ProposalView.target_node(proposal),
      isolated?: ProposalView.isolated?(proposal),
      result: ProposalView.result(project, proposal),
      integrity: Proposals.result_integrity(project.id, proposal),
      result_node: Proposals.result_node(proposal)
    }
  end

  defp decide(socket, decision) do
    project = socket.assigns.project
    user = socket.assigns[:current_user]

    if fresh_decider?(user, project) do
      result = decision_call(user, project, socket.assigns.proposal_id, decision)

      socket
      |> flash_decision(result)
      |> load_review()
      |> then(&{:noreply, &1})
    else
      {:noreply,
       put_flash(socket, :error, "Only the project owner or a granted approver may decide.")}
    end
  end

  defp decision_call(%{id: user_id}, project, proposal_id, :approved),
    do: Proposals.approve(%{id: user_id}, project.id, proposal_id)

  defp decision_call(%{id: user_id}, project, proposal_id, :rejected),
    do: Proposals.reject(%{id: user_id}, project.id, proposal_id)

  defp flash_decision(socket, {:ok, proposal}) do
    put_flash(socket, :info, "Proposal #{proposal.status}.")
  end

  defp flash_decision(socket, {:error, reason}) do
    put_flash(socket, :error, decision_error(reason))
  end

  # Mount authorization is not enough: every event re-reads the membership.
  defp fresh_decider?(_user, nil), do: false
  defp fresh_decider?(nil, _project), do: false

  defp fresh_decider?(%{id: user_id}, %{} = project) do
    Authorization.can_decide?(Authorization.membership(user_id, project.id))
  end

  defp decision_error(:blocked),
    do: "A critical incident is open. Resolve it before deciding, or reject and re-propose."

  defp decision_error(:integrity_failed),
    do: "The meld result could not be verified, so the proposal was not approved."

  defp decision_error(:invalid_transition),
    do: "This proposal has already been decided."

  defp decision_error(:forbidden),
    do: "Only the project owner or a granted approver may decide."

  defp decision_error(:not_found), do: "This proposal no longer exists."

  defp decision_error(_reason), do: "The decision could not be recorded."

  # A decision may only be approved when the reviewer could actually see the
  # result: isolated, unverifiable, quarantined, too large, or missing results
  # are all "review blind" and must fail closed here as well as in the context.
  defp approvable?(%{isolated?: true}), do: false
  defp approvable?(%{integrity: integrity}) when integrity != :ok, do: false
  defp approvable?(%{proposal: %{kind: :promotion}}), do: true

  defp approvable?(%{proposal: %{kind: :meld}, result: {:ok, %{quarantined?: false}}}), do: true

  defp approvable?(_review), do: false

  defp blocked_reason(%{isolated?: true}),
    do:
      "Approval is blocked until the open critical incident is resolved, or reject and re-propose."

  defp blocked_reason(%{integrity: integrity}) when integrity != :ok,
    do: "Approval is blocked: the result could not be verified (#{integrity_label(integrity)})."

  defp blocked_reason(%{result: {:ok, %{quarantined?: true}}}),
    do:
      "Approval is blocked: the result is hidden for review. Resolve the incident or reject and re-propose."

  defp blocked_reason(%{result: {:error, :too_large}}),
    do: "Approval is blocked: the result is too large to review in the browser."

  defp blocked_reason(%{result: {:error, :missing_objects}}),
    do: "Approval is blocked: the result is not available yet."

  defp blocked_reason(_review),
    do: "Approval is blocked: the result cannot be reviewed."

  defp redact_message(message), do: PublicContent.redact_message(message)

  defp integrity_label({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp integrity_label(_integrity), do: "unknown"

  defp identity(nil, _can_manage?), do: "unknown"

  # Emails are only shown to the §7.2 manager audience (owner/trusted), the same
  # audience that may read the member list; viewers see a display name.
  defp identity(user, true), do: user.email || user.name || user.id
  defp identity(user, false), do: user.name || "a project member"

  defp kind_title(:meld), do: "Meld proposal"
  defp kind_title(:promotion), do: "Promotion proposal"
  defp kind_title(_kind), do: "Proposal"

  defp format_flags([], false), do: "no flags"
  defp format_flags([], true), do: "pinned"

  defp format_flags(flags, pinned) do
    text = Enum.map_join(flags, ", ", &Atom.to_string/1)
    if pinned, do: text <> " · pinned", else: text
  end

  defp format_time(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
end
