defmodule Cadence.ServerWeb.ProjectLive do
  @moduledoc """
  Public LiveView for a project's DAG and repository browser.

  This module owns the route, the root events, and the subscription lifecycle.
  The reads and state transitions behind them live in
  `Cadence.ServerWeb.ProjectPane` (including the quarantine cache and its
  rationale), and the selected-node markup lives in
  `Cadence.ServerWeb.Components.NodePane`. Keeping this module thin is
  deliberate: the pane and its data reads are the parts that change most.
  """

  use Cadence.ServerWeb, :live_view

  alias Cadence.ServerWeb.Components.{DAG, NodePane}
  alias Cadence.ServerWeb.ProjectPane

  @impl true
  def mount(_params, _session, socket) do
    {:ok, ProjectPane.base_assigns(socket)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    case ProjectPane.handle_params(socket, params, uri) do
      {:loaded, socket, project_id} ->
        socket = subscribe(socket, project_id)
        {:noreply, ProjectPane.load_pane(socket, params)}

      {:redirect, socket} ->
        {:noreply, socket}

      {:not_found, socket, previous_project_id} ->
        {:noreply, unsubscribe(socket, previous_project_id)}
    end
  end

  @impl true
  def handle_event("toggle_pin", %{"id" => node_id}, socket) do
    ProjectPane.toggle_pin(socket, node_id)
  end

  def handle_event("toggle_raw", _params, socket) do
    ProjectPane.toggle_raw(socket)
  end

  @impl true
  def handle_event("run_action", %{"action" => action_name}, socket) do
    ProjectPane.run_action(socket, action_name)
  end

  def handle_event("run_action", _params, socket) do
    ProjectPane.run_forbidden(socket)
  end

  @impl true
  def handle_info({:incidents_changed, project_id, _incident_id, _proposal_id, node_id}, socket) do
    ProjectPane.incidents_changed(socket, project_id, node_id)
  end

  # A subscribed socket receives every project event; only incident changes can
  # affect the rendered pane (live DAG refresh is deliberately out of scope).
  def handle_info({:proposal_created, _project_id, _proposal_id}, socket), do: {:noreply, socket}

  def handle_info({:proposal_decided, _project_id, _proposal_id, _status}, socket),
    do: {:noreply, socket}

  def handle_info({:nodes_pushed, project_id, _node_ids}, socket) do
    ProjectPane.nodes_pushed(socket, project_id)
  end

  def handle_info({:preferences_updated, _project_id, _user_id}, socket), do: {:noreply, socket}

  # The project page does not render run state; a run started here navigates to
  # the run page, which owns its own subscription. Ignoring the event keeps the
  # pane from re-rendering on every status change.
  def handle_info({:action_run_updated, _project_id, _run_id, _status}, socket),
    do: {:noreply, socket}

  # Future project-topic events must not crash the public page.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @not_found do %>
      <article>
        <p class="eyebrow">404</p>
        <h1>Project not found</h1>
        <p class="note">There is no project at this address.</p>
        <p><a href="/">Back to Cadence</a></p>
      </article>
    <% else %>
      <article>
        <header class="project-header">
          <p class="eyebrow">Project</p>
          <h1>{@project.name}</h1>
          <p class="slug">/{@project.slug}</p>

          <p :if={@membership} class="project-nav">
            <.link navigate={~p"/p/#{@project.slug}/reviews"}>Reviews</.link>
            <.link :if={@actions_enabled?} navigate={~p"/p/#{@project.slug}/runs"}>Runs</.link>
          </p>

          <details :if={@members} class="members-panel">
            <summary>Members ({length(@members)})</summary>
            <ul>
              <li :for={%{membership: membership, user: user} <- @members}>
                <span>{member_name(user, membership.user_id)}</span>
                <span class="role-badge">{membership.role}</span>
                <span :if={membership.approver} class="note">approver</span>
              </li>
            </ul>
          </details>
        </header>

        <div class="project-home">
          <div class="dag-rail">
            <p :if={@node_total > @dag_layout.count} class="note">
              Showing the newest {@dag_layout.count} of {@node_total} commits.
              <.link navigate={~p"/p/#{@project.slug}/history"}>Browse the full history</.link>
            </p>

            <DAG.dag
              layout={@dag_layout}
              selected_id={@selected_node && @selected_node.id}
              project_slug={@project.slug}
            />
          </div>

          <NodePane.pane
            project={@project}
            selected_node={@selected_node}
            docs_child={@docs_child}
            can_manage?={@can_manage?}
            can_pin?={@can_pin?}
            raw_view?={@raw_view?}
            quarantine={@quarantine}
            actions={@actions}
            membership={@membership}
            repo_action={@repo_action}
            current_path={@current_path}
            tree={@tree}
            file={@file}
            readme_html={@readme_html}
            readme_name={@readme_name}
            readme_redacted?={@readme_redacted?}
            readme_notice={@readme_notice}
            path_error={@path_error}
            pane_delay={@dag_layout.pane_delay}
            provenance={@provenance}
            node_in_graph?={@node_in_graph?}
            history_page={@history_page}
          />
        </div>
      </article>
    <% end %>
    """
  end

  defp member_name(nil, user_id), do: user_id
  defp member_name(user, _user_id), do: user.name || user.email || user.id

  # The project id is only known after the slug resolves, so subscription
  # happens in `handle_params/3`, never `mount/3`. The assign keeps repeated
  # patches idempotent and moves the subscription when the slug changes.
  defp subscribe(%{assigns: %{subscribed_project_id: current}} = socket, project_id) do
    cond do
      not connected?(socket) ->
        socket

      current == project_id ->
        socket

      true ->
        if current, do: Phoenix.PubSub.unsubscribe(Cadence.Server.PubSub, "project:#{current}")
        Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:#{project_id}")
        assign(socket, :subscribed_project_id, project_id)
    end
  end

  defp unsubscribe(socket, nil), do: assign(socket, :subscribed_project_id, nil)

  defp unsubscribe(socket, project_id) do
    Phoenix.PubSub.unsubscribe(Cadence.Server.PubSub, "project:#{project_id}")
    assign(socket, :subscribed_project_id, nil)
  end
end
