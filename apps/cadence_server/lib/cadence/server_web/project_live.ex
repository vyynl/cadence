defmodule Cadence.ServerWeb.ProjectLive do
  @moduledoc """
  Public LiveView for a project's DAG and repository browser.
  """

  use Cadence.ServerWeb, :live_view

  alias Cadence.Server.{Portfolio, PublicContent}
  alias Cadence.ServerWeb.Components.{DAG, Repo}
  alias Cadence.ServerWeb.DAGLayout
  alias Cadence.ServerWeb.Metadata

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

          quarantine =
            cond do
              is_nil(selected_node) -> :ok
              previous_id == selected_node.id -> socket.assigns.quarantine
              true -> Portfolio.quarantine_status(project, selected_node)
            end

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
              not_found: false,
              quarantine: quarantine,
              repo_action: action
            )

          {:noreply, load_repo(socket, project, selected_node, params, action)}
        end

      {:error, :not_found} ->
        path = URI.parse(uri).path || "/"

        {:noreply,
         socket
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
                      {format_flags(@selected_node.flags, @selected_node.pinned)}
                    </span>
                    <time datetime={DateTime.to_iso8601(@selected_node.created_at)}>
                      {format_time(@selected_node.created_at)}
                    </time>
                    <code>{String.slice(@selected_node.git_commit_sha, 0, 12)}</code>
                  </p>
                </header>

                <Repo.quarantine :if={@quarantine == :quarantined} />

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
      not_found: false,
      quarantine: :ok,
      repo_action: :node,
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

  defp load_repo(socket, _project, nil, _params, _action), do: clear_repo(socket)

  defp load_repo(socket, project, node, params, action) do
    cond do
      socket.assigns.quarantine == :quarantined ->
        clear_repo(socket)

      action == :blob ->
        load_file(socket, project, node, param_path(params["path"]))

      action == :tree ->
        load_tree(socket, project, node, param_path(params["path"]))

      true ->
        load_tree(socket, project, node, "")
    end
  end

  defp load_tree(socket, project, node, path) do
    case Portfolio.list_dir(project, node, path) do
      {:ok, dir} ->
        {readme_html, readme_name, readme_redacted?, readme_notice} =
          if path == "", do: load_readme(project, node), else: {nil, nil, false, nil}

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

  defp load_file(socket, project, node, path) do
    path = path || ""

    case Portfolio.read_file(project, node, path) do
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

  defp load_readme(project, node) do
    case Portfolio.read_readme(project, node) do
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
