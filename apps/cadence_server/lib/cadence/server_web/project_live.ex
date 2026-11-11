defmodule Cadence.ServerWeb.ProjectLive do
  @moduledoc """
  Public LiveView for a project's DAG and repository browser.

  ## Freshness

  Once connected, the socket subscribes to `project:<id>` and reacts to
  `{:incidents_changed, …}` for the selected node: an incident that starts or
  stops isolating the snapshot re-renders the pane without a reload. The
  quarantine answer is cached on both of its inputs — the node (the snapshot
  scan is immutable) and the node's open-critical-incident flag (cheap to
  re-read) — so navigating within a node reuses the scan while an incident flip
  always re-derives (Iron Law 5). Raw view stays unfiltered.

  Live DAG refresh is deliberately not subscribed: `DAGLayout.layout/2`
  recomputes intro timing, so rebuilding the layout on `{:nodes_pushed, …}`
  would replay the animation and disturb the selected pane. A push does re-read
  only the selected node's docs child (a follow-up node can appear while the
  code snapshot is open), which leaves `dag_layout` untouched.

  Docker actions (spec §8): members see the snapshot's action list; a manager
  gets a Run control that re-reads the membership and starts a run through
  `Actions.Runs.start/4` before navigating to the run page. Run status events
  are ignored here because the run page owns that subscription.
  """

  use Cadence.ServerWeb, :live_view

  alias Cadence.Server.{
    Accounts,
    Actions,
    Authorization,
    Incidents,
    Portfolio,
    ProjectAdmin,
    PublicContent
  }

  alias Cadence.Server.Actions.Runs
  alias Cadence.ServerWeb.Components.{DAG, Repo}
  alias Cadence.ServerWeb.DAGLayout
  alias Cadence.ServerWeb.Metadata
  alias Cadence.ServerWeb.Presentation
  alias Cadence.Shared.{Node, Project}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, base_assigns())}
  end

  @impl true
  def handle_params(params, uri, socket) do
    case Portfolio.get_project_by_slug(params["slug"]) do
      {:ok, project} ->
        action = repo_action(uri, params["node_id"])

        nodes =
          project.id
          |> Portfolio.list_nodes()
          |> Enum.map(&redact_node/1)

        preview = Portfolio.preview_node(project.id)

        selected_node =
          case params["node_id"] do
            nil ->
              Enum.find(nodes, &(preview && &1.id == preview.id))

            node_id ->
              project.id
              |> Portfolio.node_for_project(node_id)
              |> redact_node()
          end

        if params["node_id"] && is_nil(selected_node) do
          {:noreply, push_navigate(socket, to: ~p"/p/#{project.slug}")}
        else
          previous_id = socket.assigns.selected_node && socket.assigns.selected_node.id
          same_node? = selected_node && previous_id == selected_node.id
          auth = auth_context(project, socket.assigns[:current_user])

          raw_view? =
            auth.can_manage? == true and same_node? == true and
              socket.assigns.raw_view? == true

          # Isolation is the node scan OR a mutable incident flag. The scan is
          # immutable per node (snapshots are immutable) and expensive; the flag
          # is cheap to re-read. Keying the cache on both inputs means a
          # tree/blob patch reuses the scan, a flag flip re-derives, and a stale
          # answer is never reused (Iron Law 5).
          {quarantine, quarantine_key, quarantine_cacheable?} =
            quarantine_answer(socket, project, selected_node, raw_view?)

          dag_layout =
            DAGLayout.layout(nodes,
              default_id: preview && preview.id,
              intro_ms: dag_intro_ms()
            )

          path = URI.parse(uri).path || "/p/#{project.slug}"

          socket =
            socket
            |> maybe_subscribe(project)
            |> assign(
              page_title: project.name,
              page_description:
                "#{project.name} on Cadence — session history and repository snapshot.",
              canonical_url: Metadata.canonical(path),
              project: project,
              dag_layout: dag_layout,
              selected_node: selected_node,
              docs_child: selected_node && Portfolio.docs_child(project.id, selected_node.id),
              actions: actions_for(project, selected_node, auth.membership, quarantine),
              not_found: false,
              quarantine: quarantine,
              quarantine_key: quarantine_key,
              quarantine_cacheable?: quarantine_cacheable?,
              repo_action: action,
              membership: auth.membership,
              members: auth.members,
              can_pin?: auth.can_pin? == true,
              can_manage?: auth.can_manage? == true,
              raw_view?: raw_view?
            )

          {:noreply, load_repo(socket, project, selected_node, params, action)}
        end

      {:error, :not_found} ->
        path = URI.parse(uri).path || "/"

        {:noreply,
         socket
         |> unsubscribe()
         |> assign(base_assigns())
         |> assign(
           page_title: "Project not found",
           page_description: "Project not found on Cadence.",
           canonical_url: Metadata.canonical(path),
           not_found: true
         )}
    end
  end

  @impl true
  def handle_event("toggle_pin", %{"id" => node_id}, socket) do
    case {socket.assigns.can_pin?, socket.assigns.project, socket.assigns.selected_node} do
      {true, %Project{} = project, %Node{}} ->
        case Portfolio.node_for_project(project.id, node_id) do
          nil ->
            {:noreply, socket}

          node ->
            case ProjectAdmin.set_pinned(project.id, node.id, not node.pinned) do
              {:ok, _node} ->
                {:noreply, reload_dag(socket)}

              {:error, _reason} ->
                {:noreply, put_flash(socket, :error, "Could not update the pin.")}
            end
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Only the project owner can pin nodes.")}
    end
  end

  def handle_event("toggle_raw", _params, socket) do
    case {socket.assigns.can_manage?, socket.assigns.project, socket.assigns.selected_node} do
      {true, %Project{} = project, %Node{} = selected_node} ->
        raw_view? = !socket.assigns.raw_view?

        {quarantine, quarantine_key, quarantine_cacheable?} =
          quarantine_answer(socket, project, selected_node, raw_view?)

        socket =
          assign(socket,
            raw_view?: raw_view?,
            quarantine: quarantine,
            quarantine_key: quarantine_key,
            quarantine_cacheable?: quarantine_cacheable?
          )

        {:noreply, reload_repo(socket)}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Only project owners and trusted members can view raw content."
         )}
    end
  end

  @impl true
  def handle_event("run_action", %{"action" => action_name}, socket) do
    case {socket.assigns.project, socket.assigns.selected_node, socket.assigns[:current_user]} do
      {%Project{} = project, %Node{} = node, %{id: user_id}} ->
        # Mount/handle_params authorization is not enough: re-read the membership
        # and refresh the control assign before any run row is written (Iron
        # Law 10). Runs.start/4 re-checks as well.
        membership = Portfolio.membership_for(user_id, project.id)
        can_manage? = Authorization.can_manage?(membership)

        socket = assign(socket, membership: membership, can_manage?: can_manage?)

        if can_manage? do
          # Raw view forces the rendered quarantine answer to :ok, so re-derive
          # the real status before writing a run row. Normal view reuses the
          # cached answer, keeping the store walk to staging (6b's single-scan
          # rule); staging remains the authority either way.
          quarantine =
            if socket.assigns.raw_view? do
              Portfolio.quarantine_status(project, node)
            else
              socket.assigns.quarantine
            end

          cond do
            not Actions.enabled?() ->
              {:noreply, put_flash(socket, :error, run_error(:disabled))}

            quarantine == :quarantined ->
              {:noreply,
               put_flash(socket, :error, "This snapshot is quarantined and cannot run actions.")}

            true ->
              case Runs.start(%{id: user_id}, project.id, node.id, action_name) do
                {:ok, run} ->
                  {:noreply,
                   socket
                   |> put_flash(:info, "Action queued.")
                   |> push_navigate(to: ~p"/p/#{project.slug}/runs/#{run.id}")}

                {:error, reason} ->
                  {:noreply, put_flash(socket, :error, run_error(reason))}
              end
          end
        else
          {:noreply, put_flash(socket, :error, run_forbidden_message())}
        end

      _other ->
        {:noreply, put_flash(socket, :error, run_forbidden_message())}
    end
  end

  def handle_event("run_action", _params, socket) do
    {:noreply, put_flash(socket, :error, run_forbidden_message())}
  end

  @impl true
  def handle_info({:incidents_changed, project_id, _incident_id, _proposal_id, node_id}, socket) do
    project = socket.assigns.project
    selected = socket.assigns.selected_node

    if targets_selected_node?(project, selected, project_id, node_id) and
         not socket.assigns.raw_view? do
      # `quarantine_answer/4` reuses only an authoritative cached answer, so a
      # same-key event retries a scan that previously failed.
      {quarantine, key, cacheable?} = quarantine_answer(socket, project, selected, false)
      changed? = quarantine != socket.assigns.quarantine

      socket =
        assign(socket,
          quarantine: quarantine,
          quarantine_key: key,
          quarantine_cacheable?: cacheable?
        )

      {:noreply, if(changed?, do: reload_repo(socket), else: socket)}
    else
      {:noreply, socket}
    end
  end

  # A subscribed socket receives every project event; only incident changes can
  # affect the rendered pane (live DAG refresh is deliberately out of scope).
  def handle_info({:proposal_created, _project_id, _proposal_id}, socket), do: {:noreply, socket}

  def handle_info({:proposal_decided, _project_id, _proposal_id, _status}, socket),
    do: {:noreply, socket}

  def handle_info({:nodes_pushed, project_id, _node_ids}, socket) do
    project = socket.assigns.project
    selected = socket.assigns.selected_node

    if project && project.id == project_id && selected do
      {:noreply, assign(socket, docs_child: Portfolio.docs_child(project.id, selected.id))}
    else
      {:noreply, socket}
    end
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
            <.link :if={Actions.enabled?()} navigate={~p"/p/#{@project.slug}/runs"}>Runs</.link>
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
          <DAG.dag
            layout={@dag_layout}
            selected_id={@selected_node && @selected_node.id}
            project_slug={@project.slug}
          />

          <section class="repo-panel reveal" style={"--pane-delay: #{@dag_layout.pane_delay}ms"}>
            <div
              id={pane_id(@selected_node, @repo_action, @current_path)}
              class="node-pane"
              phx-update="replace"
            >
              <%= if @selected_node do %>
                <header class="node-header">
                  <p class="eyebrow">Node</p>
                  <h2>{@selected_node.message || "(no message)"}</h2>
                  <p class="node-meta">
                    <span class="flag-badge">
                      {Presentation.format_flags(@selected_node.flags, @selected_node.pinned)}
                    </span>
                    <span class={Presentation.docs_badge_class(@selected_node.docs_state)}>
                      {Presentation.docs_state_label(@selected_node.docs_state)}
                    </span>
                    <.link
                      :if={@docs_child}
                      patch={~p"/p/#{@project.slug}/n/#{@docs_child.id}"}
                      class={Presentation.docs_badge_class(@docs_child.docs_state)}
                      title="Open the follow-up node carrying this snapshot's docs"
                    >
                      {Presentation.docs_state_label(@docs_child.docs_state)} · child node
                    </.link>
                    <time datetime={DateTime.to_iso8601(@selected_node.created_at)}>
                      {Presentation.format_time(@selected_node.created_at)}
                    </time>
                    <code>{String.slice(@selected_node.git_commit_sha, 0, 12)}</code>
                  </p>
                </header>

                <div :if={@can_manage?} class="admin-controls">
                  <button
                    :if={@can_pin?}
                    type="button"
                    class="admin-button"
                    phx-click="toggle_pin"
                    phx-value-id={@selected_node.id}
                  >
                    {if @selected_node.pinned, do: "Unpin node", else: "Pin node"}
                  </button>

                  <button type="button" class="admin-button" phx-click="toggle_raw">
                    {if @raw_view?, do: "Show filtered view", else: "Show raw content"}
                  </button>

                  <span :if={@raw_view?} class="admin-warning">
                    Raw view — unfiltered content.
                  </span>
                </div>

                <%= if @quarantine != :quarantined do %>
                  <%= case @actions do %>
                    <% {:ok, actions} -> %>
                      <section class="actions-panel" aria-label="Actions">
                        <p class="eyebrow">Actions</p>
                        <ul class="action-list">
                          <li :for={action <- actions}>
                            <div class="action-heading">
                              <span class="action-name">{action.name}</span>
                              <button
                                :if={@can_manage?}
                                type="button"
                                class="admin-button button-primary"
                                phx-click="run_action"
                                phx-value-action={action.name}
                                phx-disable-with="Starting…"
                              >
                                Run
                              </button>
                            </div>
                            <p :if={action.description} class="note">{action.description}</p>
                            <code>{action.command}</code>
                          </li>
                        </ul>
                        <p :if={@membership} class="action-history">
                          <.link navigate={~p"/p/#{@project.slug}/runs"}>Run history</.link>
                        </p>
                      </section>
                    <% :invalid -> %>
                      <section class="actions-panel" aria-label="Actions">
                        <p class="eyebrow">Actions</p>
                        <p class="note">The actions manifest could not be read.</p>
                      </section>
                    <% nil -> %>
                  <% end %>
                <% end %>

                <Repo.quarantine :if={@quarantine == :quarantined and not @raw_view?} />

                <div :if={@quarantine != :quarantined and @path_error} class="path-error">
                  <p class="note">{@path_error}</p>
                  <.link patch={~p"/p/#{@project.slug}/n/#{@selected_node.id}"}>
                    Back to repository root
                  </.link>
                </div>

                <Repo.file
                  :if={@quarantine != :quarantined and is_nil(@path_error) and @file}
                  file={@file}
                  project_slug={@project.slug}
                  node_id={@selected_node.id}
                />

                <div :if={@quarantine != :quarantined and is_nil(@path_error) and @tree}>
                  <Repo.tree
                    entries={@tree.entries}
                    hidden_count={@tree.hidden_count}
                    truncated?={@tree.truncated?}
                    project_slug={@project.slug}
                    node_id={@selected_node.id}
                    current_path={@current_path}
                  />

                  <Repo.readme
                    :if={@readme_html}
                    html={@readme_html}
                    name={@readme_name}
                    redacted?={@readme_redacted?}
                  />

                  <p
                    :if={is_nil(@readme_html) and @readme_notice}
                    class="note"
                  >
                    {@readme_notice}
                  </p>

                  <p
                    :if={is_nil(@readme_html) and is_nil(@readme_notice) and @current_path == ""}
                    class="note"
                  >
                    No README in this snapshot.
                  </p>
                </div>
              <% else %>
                <p class="empty">No commits yet.</p>
              <% end %>
            </div>
          </section>
        </div>
      </article>
    <% end %>
    """
  end

  defp base_assigns do
    [
      page_title: "Cadence",
      page_description: nil,
      canonical_url: nil,
      project: nil,
      dag_layout: DAGLayout.layout([]),
      selected_node: nil,
      docs_child: nil,
      actions: nil,
      not_found: false,
      quarantine: :ok,
      quarantine_key: nil,
      quarantine_cacheable?: false,
      repo_action: :node,
      membership: nil,
      members: nil,
      can_pin?: false,
      can_manage?: false,
      raw_view?: false,
      subscribed_project_id: nil,
      current_path: "",
      tree: nil,
      file: nil,
      readme_html: nil,
      readme_name: nil,
      readme_redacted?: false,
      readme_notice: nil,
      path_error: nil
    ]
  end

  # The project id is only known after the slug resolves, so subscription
  # happens in `handle_params/3`, never `mount/3`. The assign keeps repeated
  # patches idempotent and moves the subscription when the slug changes.
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

  # Same-variable matching compares the project and node ids in the event with
  # the rendered ones, so an incident for another node (or a project-scoped
  # incident with nil ids) leaves the pane alone.
  defp targets_selected_node?(%{id: project_id}, %{id: node_id}, project_id, node_id), do: true
  defp targets_selected_node?(_project, _selected, _project_id, _node_id), do: false

  defp quarantine_answer(_socket, _project, nil, _raw_view?), do: {:ok, nil, false}
  defp quarantine_answer(_socket, _project, _node, true), do: {:ok, nil, false}

  defp quarantine_answer(socket, project, node, false) do
    key = quarantine_key(project, node)

    if socket.assigns.quarantine_key == key and socket.assigns.quarantine_cacheable? do
      {socket.assigns.quarantine, key, true}
    else
      # A failed scan is `:quarantined` for rendering but must not be cached;
      # the snapshot may become readable (object repair, cap raised) later.
      case Portfolio.quarantine_status_with_source(project, node) do
        {:ok, status} -> {status, key, true}
        {:error, :unverifiable} -> {:quarantined, key, false}
      end
    end
  end

  # The immutable half of isolation (a snapshot scan depends only on the node)
  # plus the mutable half (an open critical node incident), so the cache is
  # keyed on every input that can change the answer.
  defp quarantine_key(project, node) do
    {node.id, Incidents.blocking_node?(project.id, node.id)}
  end

  defp load_repo(socket, _project, nil, _params, _action), do: clear_repo(socket)

  defp load_repo(socket, project, node, params, action) do
    filtered? = not socket.assigns.raw_view?
    path = param_path(params["path"])

    cond do
      filtered? and socket.assigns.quarantine == :quarantined ->
        clear_repo(socket, path)

      action == :blob ->
        load_file(socket, project, node, path, filtered?)

      action == :tree ->
        load_tree(socket, project, node, path, filtered?)

      true ->
        load_tree(socket, project, node, "", filtered?)
    end
  end

  defp load_tree(socket, project, node, path, filtered?) do
    case Portfolio.list_dir(project, node, path, filter: filtered?) do
      {:ok, dir} ->
        {readme_html, readme_name, readme_redacted?, readme_notice} =
          if path == "",
            do: load_readme(project, node, filtered?),
            else: {nil, nil, false, nil}

        assign(socket,
          current_path: path,
          tree: dir,
          file: nil,
          readme_html: readme_html,
          readme_name: readme_name,
          readme_redacted?: readme_redacted?,
          readme_notice: readme_notice,
          path_error: nil
        )

      {:error, :not_found} ->
        socket
        |> clear_repo(path)
        |> assign(path_error: "Directory not found.")
    end
  end

  defp load_file(socket, project, node, path, filtered?) do
    path = path || ""

    case Portfolio.read_file(project, node, path, filter: filtered?) do
      {:ok, file} ->
        assign(socket,
          current_path: path,
          file: file,
          tree: nil,
          readme_html: nil,
          readme_name: nil,
          readme_redacted?: false,
          readme_notice: nil,
          path_error: nil
        )

      {:error, :hidden} ->
        socket
        |> clear_repo(path)
        |> assign(path_error: "This file is not publicly available.")

      {:error, :not_found} ->
        socket
        |> clear_repo(path)
        |> assign(path_error: "File not found.")
    end
  end

  defp load_readme(project, node, filtered?) do
    case Portfolio.read_readme(project, node, filter: filtered?) do
      {:ok, %{binary?: true, name: name}} ->
        {nil, name, false, "README is binary and was not rendered."}

      {:ok, %{truncated?: true, name: name}} ->
        {nil, name, false, "README is too large to render."}

      {:ok, %{markdown: markdown, name: name, redacted?: redacted?}} ->
        {render_markdown(markdown), name, redacted?, nil}

      {:error, :not_found} ->
        {nil, nil, false, nil}
    end
  end

  defp render_markdown(nil), do: nil

  defp render_markdown(markdown) do
    case MDEx.to_html(markdown,
           extension: [autolink: true, strikethrough: true, table: true, tasklist: true],
           render: [unsafe: false],
           sanitize: MDEx.Document.default_sanitize_options()
         ) do
      {:ok, html} -> html
      {:error, _reason} -> "<p>README could not be rendered.</p>"
    end
  end

  defp reload_dag(socket) do
    project = socket.assigns.project

    nodes =
      project.id
      |> Portfolio.list_nodes()
      |> Enum.map(&redact_node/1)

    preview = Portfolio.preview_node(project.id)
    selected_id = socket.assigns.selected_node && socket.assigns.selected_node.id
    selected_node = Enum.find(nodes, &(&1.id == selected_id))

    dag_layout =
      DAGLayout.layout(nodes,
        default_id: preview && preview.id,
        intro_ms: dag_intro_ms()
      )

    assign(socket,
      selected_node: selected_node,
      dag_layout: dag_layout
    )
  end

  defp reload_repo(socket) do
    params = %{"path" => socket.assigns.current_path}
    socket = reload_actions(socket)

    load_repo(
      socket,
      socket.assigns.project,
      socket.assigns.selected_node,
      params,
      socket.assigns.repo_action
    )
  end

  # The panel depends on mutable quarantine state, so it is recomputed whenever
  # the pane reloads for an incident flip or a raw toggle. Snapshots are
  # immutable, so a pin/tree patch does not need it.
  defp reload_actions(socket) do
    project = socket.assigns.project
    node = socket.assigns.selected_node

    assign(
      socket,
      actions: actions_for(project, node, socket.assigns.membership, socket.assigns.quarantine)
    )
  end

  defp auth_context(project, current_user) do
    membership =
      if current_user do
        Portfolio.membership_for(current_user.id, project.id)
      end

    can_manage? = membership && membership.role in [:owner, :trusted]
    can_pin? = membership && membership.role == :owner

    %{
      membership: membership,
      can_manage?: can_manage?,
      can_pin?: can_pin?,
      members: if(can_manage?, do: load_members(project.id), else: nil)
    }
  end

  defp load_members(project_id) do
    memberships = Portfolio.list_memberships(project_id)
    users = Accounts.users_by_ids(Enum.map(memberships, & &1.user_id))

    Enum.map(memberships, fn membership ->
      %{membership: membership, user: Map.get(users, membership.user_id)}
    end)
  end

  defp member_name(nil, user_id), do: user_id
  defp member_name(user, _user_id), do: user.name || user.email || user.id

  defp clear_repo(socket, path \\ "") do
    assign(socket,
      current_path: path,
      tree: nil,
      file: nil,
      readme_html: nil,
      readme_name: nil,
      readme_redacted?: false,
      readme_notice: nil,
      path_error: nil
    )
  end

  defp param_path(nil), do: ""
  defp param_path(path) when is_list(path), do: Enum.join(path, "/")
  defp param_path(path) when is_binary(path), do: path

  defp repo_action(_uri, nil), do: :node

  defp repo_action(uri, node_id) do
    segments =
      uri
      |> URI.parse()
      |> Map.get(:path)
      |> Kernel.||("")
      |> String.split("/", trim: true)

    case Enum.find_index(segments, &(&1 == node_id)) do
      nil -> :node
      index -> action_from_segments(Enum.at(segments, index + 1))
    end
  end

  defp action_from_segments("tree"), do: :tree
  defp action_from_segments("blob"), do: :blob
  defp action_from_segments(_segment), do: :node

  defp pane_id(nil, _action, _path), do: "node-pane-empty"

  defp pane_id(node, action, path) do
    suffix =
      path
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_-]/, "-")

    "node-pane-#{node.id}-#{action}-#{suffix}"
  end

  defp redact_node(nil), do: nil

  defp redact_node(node) do
    Map.put(node, :message, PublicContent.redact_message(node.message))
  end

  # Nothing to show: no manifest, actions disabled, or the viewer is not a
  # member. A malformed or oversized manifest is a shape-only notice, never a
  # partial list and never a crash.
  defp actions_for(_project, nil, _membership, _quarantine), do: nil
  defp actions_for(_project, _node, _membership, :quarantined), do: nil

  defp actions_for(project, node, membership, _quarantine),
    do: actions_view(Actions.list(project, node, membership))

  defp actions_view({:ok, %{actions: []}}), do: nil
  defp actions_view({:ok, %{actions: actions}}), do: {:ok, actions}
  defp actions_view({:error, reason}) when reason in [:not_found, :disabled, :forbidden], do: nil
  defp actions_view({:error, _reason}), do: :invalid

  defp run_forbidden_message do
    "Only the project owner or a trusted member can run actions."
  end

  defp run_error(:disabled), do: "Action runs are disabled for this deployment."
  defp run_error(:forbidden), do: run_forbidden_message()
  defp run_error(:not_found), do: "That action or snapshot is no longer available."
  defp run_error(:quarantined), do: "This snapshot is quarantined and cannot run actions."

  defp run_error(:queue_full),
    do: "The run queue is full. Wait for a run to finish and try again."

  defp run_error(:unknown_action), do: "That action is no longer in the manifest."
  defp run_error(:run_failed), do: "The run could not be started."
  defp run_error(%Ecto.Changeset{}), do: "The run request was invalid."
  defp run_error(_reason), do: "The run could not be started."

  defp dag_intro_ms do
    Application.get_env(:cadence_server, :dag_intro_ms, 1200)
  end
end
