defmodule Cadence.ServerWeb.ProjectLive do
  @moduledoc """
  Public LiveView for a project's DAG and node inspector.
  """

  use Cadence.ServerWeb, :live_view

  alias Cadence.Server.{Portfolio, PublicContent}
  alias Cadence.ServerWeb.Components.DAG, as: DAGComponent
  alias Cadence.ServerWeb.DAGLayout

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Cadence",
       project: nil,
       dag_layout: DAGLayout.layout([]),
       selected_node: nil,
       not_found: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case Portfolio.get_project_by_slug(params["slug"]) do
      {:ok, project} ->
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
          dag_layout =
            DAGLayout.layout(nodes,
              default_id: preview && preview.id,
              intro_ms: dag_intro_ms()
            )

          {:noreply,
           assign(socket,
             page_title: project.name,
             project: project,
             dag_layout: dag_layout,
             selected_node: selected_node,
             not_found: false
           )}
        end

      {:error, :not_found} ->
        {:noreply,
         assign(socket,
           page_title: "Project not found",
           project: nil,
           dag_layout: DAGLayout.layout([]),
           selected_node: nil,
           not_found: true
         )}
    end
  end

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
        </header>

        <div class="project-home">
          <DAGComponent.dag
            layout={@dag_layout}
            selected_id={@selected_node && @selected_node.id}
            project_slug={@project.slug}
          />

          <section class="repo-panel reveal" style={"--pane-delay: #{@dag_layout.pane_delay}ms"}>
            <div
              id={"node-pane-#{@selected_node && @selected_node.id}"}
              class="node-pane"
              phx-update="replace"
            >
              <%= if @selected_node do %>
                <header class="node-header">
                  <p class="eyebrow">Node</p>
                  <h2>{@selected_node.message || "(no message)"}</h2>
                  <p class="node-meta">
                    <span class="flag-badge">
                      {format_flags(@selected_node.flags, @selected_node.pinned)}
                    </span>
                    <time datetime={DateTime.to_iso8601(@selected_node.created_at)}>
                      {format_time(@selected_node.created_at)}
                    </time>
                    <code>{String.slice(@selected_node.git_commit_sha, 0, 12)}</code>
                  </p>
                </header>

                <p class="note">Repository browser lands in 3b-2.</p>
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

  defp redact_node(nil), do: nil

  defp redact_node(node) do
    Map.put(node, :message, PublicContent.redact_message(node.message))
  end

  defp format_flags([], false), do: "no flags"
  defp format_flags([], true), do: "pinned"

  defp format_flags(flags, pinned) do
    text = Enum.map_join(flags, ", ", &Atom.to_string/1)
    if pinned, do: text <> " · pinned", else: text
  end

  defp format_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp dag_intro_ms do
    Application.get_env(:cadence_server, :dag_intro_ms, 1200)
  end
end
