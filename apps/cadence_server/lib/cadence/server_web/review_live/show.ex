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
  work — the capped result walks and the integrity walk — never runs in
  `mount/3`. An isolated proposal skips the result walks entirely.

  ## Freshness

  The payload (including `isolated?`, and the result diff when the result is not
  isolated) is recomputed on every `handle_params`, after every decision, and
  when the project topic announces this proposal's decision or an incident that
  touches it. An incident is
  relevant when it is proposal-linked, or when it quarantines the node approval
  would promote/attach (`Proposals.decision_node/1`): that node blocks the
  decision even though it does not isolate the result. Incidents on unrelated
  nodes are ignored so they never pay the capped blob walks. Every handled
  event re-reads the membership, so a revoked grant removes the controls on the
  next event. The decision itself also re-reads the membership and the context
  re-checks incidents and roles, so a stale click still fails closed with
  `:blocked`/`:forbidden`.
  """

  use Cadence.ServerWeb, :live_view

  alias Cadence.Server.{
    Accounts,
    Authorization,
    Incidents,
    ProposalView,
    Proposals,
    PublicContent
  }

  alias Cadence.ServerWeb.Components.ProposalResult
  alias Cadence.ServerWeb.Presentation
  alias Cadence.ServerWeb.ReviewAccess
  alias Cadence.Shared.UUID
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Review",
       project: nil,
       proposal_id: nil,
       not_found: false,
       can_decide?: false,
       can_manage?: false,
       subscribed_project_id: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case ReviewAccess.authorize(socket.assigns[:current_user], params["slug"]) do
      {:ok, project, membership} ->
        socket =
          socket
          |> maybe_subscribe(project)
          |> assign(
            page_title: "Review · #{project.name}",
            project: project,
            proposal_id: normalize_id(params["proposal_id"]),
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
         socket
         |> unsubscribe()
         |> assign(
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
  def handle_info({:proposal_decided, project_id, proposal_id, _status}, socket) do
    {:noreply, reload_after_event(socket, project_id, proposal_id)}
  end

  def handle_info({:incidents_changed, project_id, _incident_id, proposal_id, node_id}, socket) do
    if incident_relevant?(socket, proposal_id, node_id) do
      {:noreply, reload_project_event(socket, project_id)}
    else
      {:noreply, socket}
    end
  end

  # A subscribed socket receives every project event; a creation elsewhere, a
  # pushed node, and preference writes cannot change this proposal.
  def handle_info({:proposal_created, _project_id, _proposal_id}, socket), do: {:noreply, socket}

  def handle_info({:nodes_pushed, _project_id, _node_ids}, socket), do: {:noreply, socket}

  def handle_info({:preferences_updated, _project_id, _user_id}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <article class="review-page">
      <%= if @not_found do %>
        <p class="eyebrow">404</p>
        <h1>Project not found</h1>
        <p class="note">There is no project at this address.</p>
        <p><a class="button-link" href="/">Back to Cadence</a></p>
      <% else %>
        <p class="eyebrow">
          <a class="button-link" href={~p"/p/#{@project.slug}/reviews"}>Reviews</a>
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

            <p><a class="button-link" href={~p"/p/#{@project.slug}/reviews"}>Back to reviews</a></p>
          </:failed>

          <header class="project-header">
            <p class="eyebrow">Proposal</p>
            <h1>{Presentation.kind_title(review.proposal.kind)}</h1>

            <p class="node-meta">
              <span class={Presentation.status_badge_class(review.proposal.status)}>
                {review.proposal.status}
              </span>
              <span :if={review.proposal.created_at}>
                opened
                <time datetime={DateTime.to_iso8601(review.proposal.created_at)}>
                  {Presentation.format_time(review.proposal.created_at)}
                </time>
              </span>
              <span :if={review.proposal.decided_at}>
                decided
                <time datetime={DateTime.to_iso8601(review.proposal.decided_at)}>
                  {Presentation.format_time(review.proposal.decided_at)}
                </time>
              </span>
            </p>

            <p class="node-meta">
              <span>Proposed by {identity(review.proposer, @can_manage?)}</span>
              <span :if={review.reviewer}>· Reviewed by {identity(review.reviewer, @can_manage?)}</span>
            </p>

            <p class="note">
              <a class="button-link" href={~p"/proposals/#{review.proposal.token}"}>Public read-only link</a>
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
                  <span class="flag-badge">{Presentation.format_flags(parent.flags, parent.pinned)}</span>
                  <code>{String.slice(parent.git_commit_sha, 0, 12)}</code>
                </p>
              </li>
            </ul>

            <p :if={review.parents == []} class="note">No parent nodes are available.</p>
          </section>

          <section class="proposal-result">
            <ProposalResult.result
              result={if review.isolated?, do: :isolated, else: review.result}
              audience={:review}
              project_slug={@project.slug}
              target_node={review.target_node}
            />

            <div :if={review.integrity != :ok} class="callout callout-warning">
              <p class="note">
                The stored result could not be verified ({integrity_label(review.integrity)}), so it cannot be approved.
              </p>
            </div>
          </section>

          <section :if={@can_decide? and review.proposal.status == :pending} class="admin-controls">
            <h2>Decision</h2>

            <%= if approvable?(review) do %>
              <button
                type="button"
                class="admin-button button-primary"
                phx-click="approve"
                phx-disable-with="Deciding…"
              >
                Approve
              </button>
            <% else %>
              <p class="note">{blocked_reason(review)}</p>
            <% end %>

            <button
              type="button"
              class="admin-button button-danger"
              phx-click="reject"
              phx-disable-with="Deciding…"
            >
              Reject
            </button>
          </section>

          <section :if={review.proposal.status != :pending} class="proposal-result">
            <h2>Decision</h2>
            <p class="note">
              This proposal was {review.proposal.status}. Only pending proposals can be decided.
            </p>
            <p :if={review.result_node}>
              <a class="button-link" href={~p"/p/#{@project.slug}/n/#{review.result_node.id}"}>
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

  # The project id is only known once the slug resolves, so subscription
  # happens in `handle_params/3`, never `mount/3`. The assign keeps repeated
  # patches idempotent and lets a project switch move the subscription rather
  # than join a second topic.
  defp maybe_subscribe(%{assigns: %{subscribed_project_id: current}} = socket, project) do
    cond do
      not connected?(socket) ->
        socket

      current == project.id ->
        socket

      true ->
        if current, do: Phoenix.PubSub.unsubscribe(Cadence.Server.PubSub, "project:#{current}")
        Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:#{project.id}")
        assign(socket, :subscribed_project_id, project.id)
    end
  end

  defp unsubscribe(%{assigns: %{subscribed_project_id: nil}} = socket), do: socket

  defp unsubscribe(socket) do
    Phoenix.PubSub.unsubscribe(
      Cadence.Server.PubSub,
      "project:#{socket.assigns.subscribed_project_id}"
    )

    assign(socket, :subscribed_project_id, nil)
  end

  # A decision only matters to its own page.
  defp reload_after_event(socket, project_id, proposal_id) do
    if socket.assigns.proposal_id == proposal_id do
      reload_project_event(socket, project_id)
    else
      socket
    end
  end

  # An incident matters when it touches this proposal or the node the decision
  # would promote/attach. Anything else keeps the page — and the capped blob
  # walks — untouched.
  defp incident_relevant?(socket, proposal_id, node_id) do
    incident_relevant?(
      socket.assigns.proposal_id,
      decision_node_ids(socket),
      review_loaded?(socket),
      proposal_id,
      node_id
    )
  end

  @doc false
  # Pure decision used by `incident_relevant?/3`. Before the first successful
  # load there are no decision node ids, so every incident forces one reload
  # instead of being dropped; afterwards the proposal/node check applies.
  def incident_relevant?(local_proposal_id, decision_node_ids, loaded?, proposal_id, node_id) do
    proposal_id == local_proposal_id or node_id in decision_node_ids or not loaded?
  end

  defp review_loaded?(socket) do
    match?(%AsyncResult{ok?: true}, socket.assigns.review)
  end

  defp decision_node_ids(socket) do
    case socket.assigns.review do
      %AsyncResult{ok?: true, result: %{} = review} -> Map.get(review, :decision_node_ids, [])
      _other -> []
    end
  end

  defp reload_project_event(socket, project_id) do
    if match?(%{id: ^project_id}, socket.assigns.project) do
      socket
      |> refresh_roles(socket.assigns.project)
      |> load_review()
    else
      socket
    end
  end

  # D6: a revoked grant must stop rendering the controls (and emails) on the
  # next project event, not only after a reload.
  defp refresh_roles(socket, project) do
    membership = Authorization.membership(socket.assigns.current_user.id, project.id)

    assign(socket,
      can_decide?: Authorization.can_decide?(membership),
      can_manage?: Authorization.can_manage?(membership)
    )
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

    decision_node = Proposals.decision_node(proposal)
    isolated? = ProposalView.isolated?(proposal)

    %{
      proposal: proposal,
      proposer: Map.get(identities, proposal.proposer_id),
      reviewer: Map.get(identities, proposal.reviewer_id),
      parents: ProposalView.parents(proposal),
      target_node: ProposalView.target_node(proposal),
      isolated?: isolated?,
      # Isolation hides the result, so its walks and cache entry would be dead
      # work. `isolated?` is read only by `approvable?/1` and `blocked_reason/1`;
      # the template maps it to `:isolated` and never reads `result` here, which
      # stays nil for an isolated proposal.
      result: if(isolated?, do: nil, else: ProposalView.result(project, proposal)),
      integrity: Proposals.result_integrity(project.id, proposal),
      result_node: Proposals.result_node(proposal),
      # The context refuses approval when an open critical incident quarantines
      # this node (`Proposals.ensure_node_approvable/2`); the page must agree.
      node_blocked?:
        not is_nil(decision_node) and Incidents.blocking_node?(project.id, decision_node.id),
      decision_node_ids: if(decision_node, do: [decision_node.id], else: [])
    }
  end

  defp decide(socket, decision) do
    project = socket.assigns.project
    user = socket.assigns[:current_user]

    if fresh_decider?(user, project) do
      result = decision_call(user, project, socket.assigns.proposal_id, decision)

      socket
      |> refresh_roles(project)
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
  # The node the decision would move the line onto is checked too: a node
  # incident blocks the context even when the result itself is readable.
  defp approvable?(%{node_blocked?: true}), do: false
  defp approvable?(%{isolated?: true}), do: false
  defp approvable?(%{integrity: integrity}) when integrity != :ok, do: false
  defp approvable?(%{proposal: %{kind: :promotion}}), do: true

  defp approvable?(%{proposal: %{kind: :meld}, result: {:ok, %{quarantined?: false}}}), do: true

  defp approvable?(_review), do: false

  defp blocked_reason(%{node_blocked?: true}),
    do:
      "Approval is blocked: a critical incident quarantines the node this proposal would promote or attach. Resolve it first."

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

  # `Proposals.get/3` casts the id and events carry the canonical lowercase
  # UUID, so the assign must be canonical too. Otherwise a mixed-case URL
  # renders the page but never matches an event, silently stopping live
  # updates. An invalid id is kept as-is so the not-found path still renders.
  defp normalize_id(id) do
    case UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  defp integrity_label({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp integrity_label(_integrity), do: "unknown"

  defp identity(nil, _can_manage?), do: "unknown"

  # Emails are only shown to the §7.2 manager audience (owner/trusted), the same
  # audience that may read the member list; viewers see a display name.
  defp identity(user, true), do: user.email || user.name || user.id
  defp identity(user, false), do: user.name || "a project member"
end
