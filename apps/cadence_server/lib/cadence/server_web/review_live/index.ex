defmodule Cadence.ServerWeb.ReviewLive.Index do
  @moduledoc """
  Member-only review hub for a project (spec §6.6, §7.2).

  The public `/proposals/:token` page stays the read-only, identity-free,
  capability view. This page is the authenticated counterpart: it lists every
  proposal of the project, pending first, for any member with `can_view?/1`.

  Authorization runs in `handle_params/3` because a refused visitor must be
  redirected, and an `assign_async` failure cannot navigate. `mount/3` stays
  database-free; the proposal list and the open-incident panel are loaded with
  `assign_async/3`.

  Incident controls are rendered only for `can_decide?/1` and every event
  re-checks that role (Iron Law 10). Proposal-linked incidents resolve only
  after a clean re-scan — a remaining secret must be fixed by rejecting and
  re-proposing — while node and project incidents resolve by acknowledgment
  (§6.7).

  ## Freshness

  After the socket connects, `handle_params/3` subscribes to `project:<id>`
  once. `{:proposal_created, …}` and `{:proposal_decided, …}` reload the
  queue, `{:incidents_changed, …}` reloads the incident panel, and every
  handled event re-reads the membership before assigning `can_decide?` so a
  revoked grant stops rendering the controls. A local decision or resolution
  keeps its explicit reload and may also receive its own broadcast, which is
  accepted as one redundant async load.
  """

  use Cadence.ServerWeb, :live_view

  require Logger

  alias Cadence.Server.{Authorization, Incidents, ProposalView, Proposals}
  alias Cadence.ServerWeb.Components.Incident
  alias Cadence.ServerWeb.Presentation
  alias Cadence.ServerWeb.ReviewAccess

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Reviews",
       project: nil,
       not_found: false,
       can_decide?: false,
       subscribed_project_id: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case ReviewAccess.authorize(socket.assigns[:current_user], params["slug"]) do
      {:ok, project, membership} ->
        user_id = socket.assigns.current_user.id

        socket =
          socket
          |> maybe_subscribe(project)
          |> assign(
            page_title: "Reviews · #{project.name}",
            project: project,
            not_found: false,
            can_decide?: Authorization.can_decide?(membership)
          )

        {:noreply,
         socket
         |> assign_async(:proposals, fn -> load_proposals(project, user_id) end)
         |> assign_async(:incidents, fn -> load_incidents(project, user_id) end)}

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
           can_decide?: false
         )}
    end
  end

  @impl true
  def handle_event("resolve_incident", %{"id" => incident_id}, socket) do
    project = socket.assigns.project
    user = socket.assigns[:current_user]
    # Re-read the role and refresh the assign: mount/handle_params authorization
    # is not enough, and a revoked grant must also stop rendering the control.
    allowed? = fresh_decider?(user, project)

    socket = assign(socket, :can_decide?, allowed?)

    if allowed? do
      result =
        Incidents.resolve(user, project.id, incident_id,
          verify: &ProposalView.verify_resolution/1
        )

      socket
      |> flash_resolution(result)
      |> load_incidents()
      |> then(&{:noreply, &1})
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Only the project owner or a granted approver may resolve incidents."
       )}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:proposal_created, project_id, _proposal_id}, socket) do
    {:noreply, reload_proposals_for(socket, project_id)}
  end

  def handle_info({:proposal_decided, project_id, _proposal_id, _status}, socket) do
    {:noreply, reload_proposals_for(socket, project_id)}
  end

  def handle_info({:incidents_changed, project_id, _incident_id, _proposal_id, _node_id}, socket) do
    {:noreply, reload_incidents_for(socket, project_id)}
  end

  # A subscribed socket receives every project event; these cannot change the
  # review queue or the incident panel.
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
        <p><a href="/">Back to Cadence</a></p>
      <% else %>
        <header class="project-header">
          <p class="eyebrow">Reviews</p>
          <h1>{@project.name}</h1>
          <p class="slug">
            <a href={~p"/p/#{@project.slug}"}>Back to project</a>
          </p>
        </header>

        <Incident.panel
          incidents={@incidents}
          can_decide?={@can_decide?}
          project_slug={@project.slug}
          max={Incidents.max_open_incidents()}
        />

        <section class="proposal-queue">
          <div class="panel-heading">
            <h2>Proposals</h2>
          </div>

          <.async_result :let={proposals} assign={@proposals}>
            <:loading>
              <p class="note">Loading proposals…</p>
            </:loading>

            <:failed>
              <p class="note">The proposal list could not be loaded.</p>
            </:failed>

            <p :if={proposals == []} class="empty">No proposals yet.</p>

            <ul :if={proposals != []} class="proposal-list">
              <li :for={proposal <- proposals} id={"proposal-#{proposal.id}"} class="proposal-row">
                <span class="file-kind">{kind_label(proposal.kind)}</span>
                <a
                  class="file-name"
                  href={~p"/p/#{@project.slug}/reviews/#{proposal.id}"}
                >
                  {Presentation.kind_title(proposal.kind)}
                </a>

                <span class={Presentation.status_badge_class(proposal.status)}>
                  {proposal.status}
                </span>

                <span class="note">{parent_count(proposal)}</span>

                <span :if={proposal.created_at} class="note">
                  opened
                  <time datetime={DateTime.to_iso8601(proposal.created_at)}>
                    {Presentation.age(proposal.created_at)}
                  </time>
                </span>

                <a class="public-link" href={~p"/proposals/#{proposal.token}"}>Public link</a>
              </li>
            </ul>
          </.async_result>
        </section>
      <% end %>
    </article>
    """
  end

  defp load_proposals(project, user_id) do
    case Proposals.list(%{id: user_id}, project.id) do
      {:ok, proposals} -> {:ok, %{proposals: sort_pending_first(proposals)}}
      {:error, _reason} -> {:error, :not_loaded}
    end
  end

  defp load_incidents(project, user_id) do
    case Incidents.list_open(%{id: user_id}, project.id) do
      {:ok, incidents} -> {:ok, %{incidents: incidents}}
      {:error, _reason} -> {:error, :not_loaded}
    end
  end

  defp load_incidents(socket) do
    project = socket.assigns.project
    user_id = socket.assigns.current_user.id

    assign_async(socket, :incidents, fn -> load_incidents(project, user_id) end)
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

  defp reload_proposals_for(socket, project_id) do
    case event_context(socket, project_id) do
      nil ->
        socket

      {project, user_id} ->
        socket
        |> refresh_role(project)
        |> assign_async(:proposals, fn -> load_proposals(project, user_id) end)
    end
  end

  defp reload_incidents_for(socket, project_id) do
    case event_context(socket, project_id) do
      nil ->
        socket

      {project, user_id} ->
        socket
        |> refresh_role(project)
        |> assign_async(:incidents, fn -> load_incidents(project, user_id) end)
    end
  end

  defp event_context(socket, project_id) do
    case {socket.assigns.project, socket.assigns[:current_user]} do
      {%{id: ^project_id}, %{id: user_id}} -> {socket.assigns.project, user_id}
      _other -> nil
    end
  end

  # Mount authorization is not enough: a revoked grant must stop rendering the
  # controls on the next project event, not only after a reload.
  defp refresh_role(socket, project) do
    assign(socket, :can_decide?, fresh_decider?(socket.assigns[:current_user], project))
  end

  defp flash_resolution(socket, {:ok, _incident}) do
    put_flash(socket, :info, "Incident resolved.")
  end

  defp flash_resolution(socket, {:error, :still_risky}) do
    put_flash(
      socket,
      :error,
      "The result still contains sensitive content. Reject the proposal and re-propose."
    )
  end

  defp flash_resolution(socket, {:error, :unverifiable}) do
    put_flash(socket, :error, "The result could not be scanned, so the incident stays open.")
  end

  defp flash_resolution(socket, {:error, :integrity_failed}) do
    put_flash(
      socket,
      :error,
      "The stored result is no longer verifiable against the proposal, so the incident stays open. Reject it and re-propose."
    )
  end

  defp flash_resolution(socket, {:error, :forbidden}) do
    put_flash(
      socket,
      :error,
      "Only the project owner or a granted approver may resolve incidents."
    )
  end

  defp flash_resolution(socket, {:error, :not_found}) do
    put_flash(socket, :error, "This incident no longer exists.")
  end

  defp flash_resolution(socket, {:error, reason}) do
    # Only the shape is logged: changesets can carry field metadata and the
    # incident row itself is never put in a log line.
    Logger.warning("incident resolution failed: #{inspect(error_kind(reason))}")
    put_flash(socket, :error, "The incident could not be resolved.")
  end

  defp error_kind(%Ecto.Changeset{}), do: :changeset
  defp error_kind(reason) when is_atom(reason), do: reason
  defp error_kind(_reason), do: :unknown

  # Mount authorization is not enough: every event re-reads the membership.
  defp fresh_decider?(_user, nil), do: false
  defp fresh_decider?(nil, _project), do: false

  defp fresh_decider?(%{id: user_id}, %{} = project) do
    Authorization.can_decide?(Authorization.membership(user_id, project.id))
  end

  # `Proposals.list/2` is newest first; this keeps that order inside each group.
  defp sort_pending_first(proposals) do
    Enum.sort_by(proposals, fn proposal ->
      if proposal.status == :pending, do: 0, else: 1
    end)
  end

  defp parent_count(%{kind: :promotion}), do: "promotion"
  defp parent_count(%{parent_ids: ids}), do: "#{length(ids)} parents"

  defp kind_label(:meld), do: "meld"
  defp kind_label(:promotion), do: "promotion"
  defp kind_label(_kind), do: "proposal"
end
