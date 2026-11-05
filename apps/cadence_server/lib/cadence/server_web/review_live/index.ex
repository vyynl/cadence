defmodule Cadence.ServerWeb.ReviewLive.Index do
  @moduledoc """
  Member-only review hub for a project (spec §6.6, §7.2).

  The public `/proposals/:token` page stays the read-only, identity-free,
  capability view. This page is the authenticated counterpart: it lists every
  proposal of the project, pending first, for any member with `can_view?/1`.

  Authorization runs in `handle_params/3` because a refused visitor must be
  redirected, and an `assign_async` failure cannot navigate. `mount/3` stays
  database-free; the proposal list itself is loaded with `assign_async/3`.
  """

  use Cadence.ServerWeb, :live_view

  alias Cadence.Server.Proposals
  alias Cadence.ServerWeb.ReviewAccess

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Reviews",
       project: nil,
       not_found: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case ReviewAccess.authorize(socket.assigns[:current_user], params["slug"]) do
      {:ok, project, _membership} ->
        user_id = socket.assigns.current_user.id

        socket =
          assign(socket,
            page_title: "Reviews · #{project.name}",
            project: project,
            not_found: false
          )

        {:noreply, assign_async(socket, :proposals, fn -> load_proposals(project, user_id) end)}

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
           not_found: true
         )}
    end
  end

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
