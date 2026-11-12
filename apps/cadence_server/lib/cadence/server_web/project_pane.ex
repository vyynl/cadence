defmodule Cadence.ServerWeb.ProjectPane do
  @moduledoc """
  Data and event bodies for the project home pane.

  `Cadence.ServerWeb.ProjectLive` keeps the routing, the subscription
  lifecycle, and the events at the root view; this module owns the reads and
  state transitions behind them. Every function takes a socket (or the values
  it needs) and returns the updated socket, so the LiveView stays a thin
  delegation layer and its outgoing dependency fan-out stays small.

  ## Freshness

  Once connected, `ProjectLive` subscribes the socket to the project topic;
  this module handles the events that can change the pane. The quarantine
  answer is cached on both of its inputs — the node (the snapshot scan is
  immutable) and the node's open-critical-incident flag (cheap to re-read) — so
  navigating within a node reuses the scan while an incident flip always
  re-derives (Iron Law 5). Raw view stays unfiltered.

  Live DAG refresh is deliberately out of scope: `DAGLayout.layout/2` recomputes
  intro timing, so rebuilding the layout on `{:nodes_pushed, …}` would replay
  the animation and disturb the selected pane. A push re-reads only the
  selected node's docs child (a follow-up node can appear while the code
  snapshot is open), which leaves `dag_layout` untouched.

  Docker actions (spec §8): members see the snapshot's action list; a manager
  gets a Run control that re-reads the membership and starts a run through
  `Actions.Runs.start/4` before navigating to the run page. Run status events
  are ignored here because the run page owns that subscription.
  `actions_enabled?` is read once per `handle_params/3`, so a mid-session config
  flip applies on the next navigation; the click path (`run_action/2`) still
  reads `Actions.enabled?/0` live.
  """

  use Cadence.ServerWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2]

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
  alias Cadence.ServerWeb.DAGLayout
  alias Cadence.ServerWeb.Metadata
  alias Cadence.Shared.{Node, Project}

  @doc """
  Initial assigns for `mount/3`.

  The project id is only known after the slug resolves, so nothing project
  scoped is loaded here.
  """
  def base_assigns(socket) do
    socket
    |> assign(base_assigns_list())
    |> assign(:subscribed_project_id, nil)
  end

  @doc """
  Resolve the URL into pane state.

  Returns one of:

    * `{:loaded, socket, project_id}` — the project page header/pane state is
      ready; the caller owns the subscription move and then finishes with
      `load_pane/2`.
    * `{:redirect, socket}` — the requested node does not exist; the socket
      already carries a `push_navigate` back to the project home.
    * `{:not_found, socket, previous_project_id}` — the slug is unknown; the
      caller must drop the subscription it held before this call.
  """
  def handle_params(socket, params, uri) do
    case Portfolio.get_project_by_slug(params["slug"]) do
      {:ok, project} ->
        case load_project(socket, project, params, uri) do
          {:loaded, socket} -> {:loaded, socket, project.id}
          {:redirect, socket} -> {:redirect, socket}
        end

      {:error, :not_found} ->
        previous_id = socket.assigns.subscribed_project_id
        {:not_found, reset(socket, uri), previous_id}
    end
  end

  @doc """
  Finish the load with the repository browser for the requested `path`.

  This is a second step so the caller can establish the project subscription
  before the store reads run, matching the pre-split callback order.
  """
  def load_pane(socket, params) do
    load_repo(
      socket,
      socket.assigns.project,
      socket.assigns.selected_node,
      params,
      socket.assigns.repo_action
    )
  end

  @doc """
  Pin or unpin a node (owner only).
  """
  def toggle_pin(socket, node_id) do
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

  @doc """
  Toggle the unfiltered (raw) view for the selected node (owner/trusted only).
  """
  def toggle_raw(socket) do
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

  @doc """
  Start a Docker action run and navigate to its page (owner/trusted only).
  """
  def run_action(socket, action_name) do
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

  @doc """
  Refusal for a malformed `run_action` payload.
  """
  def run_forbidden(socket) do
    {:noreply, put_flash(socket, :error, run_forbidden_message())}
  end

  @doc """
  Re-derive the quarantine answer when an incident touches the selected node.

  `quarantine_answer/4` reuses only an authoritative cached answer, so a
  same-key event retries a scan that previously failed.
  """
  def incidents_changed(socket, project_id, node_id) do
    project = socket.assigns.project
    selected = socket.assigns.selected_node

    if targets_selected_node?(project, selected, project_id, node_id) and
         not socket.assigns.raw_view? do
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

  @doc """
  Refresh only the docs-child link after a push; the DAG layout is untouched.
  """
  def nodes_pushed(socket, project_id) do
    project = socket.assigns.project
    selected = socket.assigns.selected_node

    if project && project.id == project_id && selected do
      {:noreply, assign(socket, docs_child: Portfolio.docs_child(project.id, selected.id))}
    else
      {:noreply, socket}
    end
  end

  defp base_assigns_list do
    [
      page_title: "Cadence",
      page_description: nil,
      canonical_url: nil,
      project: nil,
      dag_layout: DAGLayout.layout([]),
      selected_node: nil,
      docs_child: nil,
      actions: nil,
      actions_enabled?: false,
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

  defp load_project(socket, project, params, uri) do
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
      {:redirect, push_navigate(socket, to: ~p"/p/#{project.slug}")}
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
        assign(socket,
          page_title: project.name,
          page_description:
            "#{project.name} on Cadence — session history and repository snapshot.",
          canonical_url: Metadata.canonical(path),
          project: project,
          dag_layout: dag_layout,
          selected_node: selected_node,
          docs_child: selected_node && Portfolio.docs_child(project.id, selected_node.id),
          actions: actions_for(project, selected_node, auth.membership, quarantine),
          actions_enabled?: Actions.enabled?(),
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

      {:loaded, socket}
    end
  end

  defp reset(socket, uri) do
    path = URI.parse(uri).path || "/"

    socket
    |> assign(base_assigns_list())
    |> assign(
      page_title: "Project not found",
      page_description: "Project not found on Cadence.",
      canonical_url: Metadata.canonical(path),
      not_found: true
    )
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

    can_manage? = Authorization.can_manage?(membership)
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
