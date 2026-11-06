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
  """

  use Cadence.ServerWeb, :live_view

  require Logger

  alias Cadence.Server.{Authorization, Incidents, ProposalView, Proposals}
  alias Cadence.ServerWeb.ReviewAccess

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Reviews",
       project: nil,
       not_found: false,
       can_decide?: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case ReviewAccess.authorize(socket.assigns[:current_user], params["slug"]) do
      {:ok, project, membership} ->
        user_id = socket.assigns.current_user.id

        socket =
          assign(socket,
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
         assign(socket,
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
  def render(assigns) do
    ~H"""
    <article>
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

        <.async_result :let={proposals} assign={@proposals}>
          <:loading>
            <p class="note">Loading proposals…</p>
          </:loading>

          <:failed>
            <p class="note">The proposal list could not be loaded.</p>
          </:failed>

          <p :if={proposals == []} class="empty">No proposals yet.</p>

          <ul :if={proposals != []} class="file-tree">
            <li :for={proposal <- proposals} id={"proposal-#{proposal.id}"}>
              <div class="file-row">
                <span class="file-kind">{kind_label(proposal.kind)}</span>
                <a
                  class="file-name"
                  href={~p"/p/#{@project.slug}/reviews/#{proposal.id}"}
                >
                  {kind_title(proposal.kind)}
                </a>
              </div>

              <p class="node-meta">
                <span class="flag-badge">{proposal.status}</span>
                <span>{parent_count(proposal)}</span>
                <span :if={proposal.created_at}>
                  opened
                  <time datetime={DateTime.to_iso8601(proposal.created_at)}>
                    {age(proposal.created_at)}
                  </time>
                </span>
                <a href={~p"/proposals/#{proposal.token}"}>Public link</a>
              </p>
            </li>
          </ul>
        </.async_result>

        <section class="incidents-panel">
          <h2>Open incidents</h2>

          <.async_result :let={incidents} assign={@incidents}>
            <:loading>
              <p class="note">Loading incidents…</p>
            </:loading>

            <:failed>
              <p class="note">The incident list could not be loaded.</p>
            </:failed>

            <p :if={incidents == []} class="empty">No open incidents.</p>

            <ul :if={incidents != []} class="file-tree">
              <li :for={incident <- incidents} id={"incident-#{incident.id}"}>
                <div class="file-row">
                  <span class="flag-badge">{incident.severity}</span>
                  <span class="file-kind">{incident_kind_label(incident.kind)}</span>
                  <span class="file-name">{incident.title}</span>
                </div>

                <p class="node-meta">
                  <span :if={incident.proposal_id}>
                    <a href={~p"/p/#{@project.slug}/reviews/#{incident.proposal_id}"}>Proposal</a>
                  </span>
                  <span :if={incident.node_id}>
                    <a href={~p"/p/#{@project.slug}/n/#{incident.node_id}"}>Node</a>
                  </span>
                  <span :if={is_nil(incident.proposal_id) and is_nil(incident.node_id)}>
                    Project-wide
                  </span>
                  <span :if={incident.created_at}>
                    opened
                    <time datetime={DateTime.to_iso8601(incident.created_at)}>
                      {age(incident.created_at)}
                    </time>
                  </span>
                </p>

                <% summary = details_summary(incident.details) %>
                <p :if={summary != ""} class="note">{summary}</p>
                <button
                  :if={@can_decide?}
                  type="button"
                  class="admin-button"
                  phx-click="resolve_incident"
                  phx-value-id={incident.id}
                  phx-disable-with="Resolving…"
                >
                  {if incident.proposal_id, do: "Resolve", else: "Acknowledge"}
                </button>
              </li>
            </ul>

            <p :if={length(incidents) == Incidents.max_open_incidents()} class="note">
              Showing the {Incidents.max_open_incidents()} newest open incidents.
            </p>

            <p :if={@can_decide? and incidents != []} class="note">
              Resolving a proposal incident re-scans the result: a remaining secret cannot be
              cleared here, so reject and re-propose instead. Acknowledging a node or project
              incident does not restore its content — snapshots are immutable, so rotate the
              secret and push a new node.
            </p>
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

  # Only the redacted scanner metadata the panel is allowed to show. Keys and
  # values are never taken from the map wholesale: a later incident kind may
  # carry more, and `details` is not a rendering contract.
  defp details_summary(details) when is_map(details) do
    [
      patterns_summary(Map.get(details, "patterns", Map.get(details, :patterns))),
      sensitive_paths_summary(
        Map.get(details, "sensitive_paths", Map.get(details, :sensitive_paths))
      ),
      reason_summary(Map.get(details, "reason", Map.get(details, :reason)))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp details_summary(_details), do: ""

  defp patterns_summary(patterns) when is_list(patterns) and patterns != [] do
    names =
      patterns
      |> Enum.filter(&(is_binary(&1) or is_atom(&1)))
      |> Enum.map(&to_string/1)
      |> Enum.take(5)

    if names == [], do: nil, else: "patterns: " <> Enum.join(names, ", ")
  end

  defp patterns_summary(_patterns), do: nil

  defp sensitive_paths_summary(count) when is_integer(count) and count > 0 do
    "#{count} sensitive #{if count == 1, do: "path", else: "paths"} hidden"
  end

  defp sensitive_paths_summary(_count), do: nil

  defp reason_summary(reason) when is_binary(reason) do
    case String.slice(reason, 0, 60) do
      "" -> nil
      short -> "reason: " <> short <> if(String.length(reason) > 60, do: "…", else: "")
    end
  end

  defp reason_summary(reason) when is_atom(reason) and not is_nil(reason),
    do: "reason: " <> Atom.to_string(reason)

  defp reason_summary(_reason), do: nil

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

  defp kind_title(:meld), do: "Meld proposal"
  defp kind_title(:promotion), do: "Promotion proposal"
  defp kind_title(_kind), do: "Proposal"

  defp incident_kind_label(:secret_detected), do: "secret detected"
  defp incident_kind_label(:scan_incomplete), do: "scan incomplete"
  defp incident_kind_label(:meld_failed), do: "meld failed"
  defp incident_kind_label(:agent_output_invalid), do: "agent output invalid"
  defp incident_kind_label(:missing_objects), do: "missing objects"
  defp incident_kind_label(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp incident_kind_label(_kind), do: "incident"

  defp age(%DateTime{} = created_at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), created_at, :second), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
