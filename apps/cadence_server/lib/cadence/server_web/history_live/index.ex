defmodule Cadence.ServerWeb.HistoryLive.Index do
  @moduledoc """
  Public paged commit history for a project (spec §7.1, §7.3).

  The DAG renders only the newest `CAD_DAG_MAX_NODES` nodes; this page is the
  escape hatch for everything older. It is newest first and offset-paged 50 at
  a time under `?page=N`, using the same ordering as the DAG window
  (`Cadence.Server.Portfolio.node_page/3`).

  ## Audience

  Public, like `ProjectLive`: anonymous visitors may read it. Commit messages
  are passed through `Cadence.Server.PublicContent.redact_message/1` inside the
  async load, so a detected secret never reaches the page. The imported author
  *display name* is shown; the author email is not rendered here at all.

  ## Paging

  `Cadence.Server.Portfolio.node_page/3` clamps the requested page into
  `1..total_pages` before reading, so junk means page 1 and a giant page shows
  the last page instead of an empty one. The rendered page number is derived
  from the **loaded** offset, never from the requested `?page` (the same rule as
  `RunLive.Index`): an async reload keeps its previous result renderable.

  ## Freshness

  This is a snapshot list: it is not subscribed to PubSub and refreshes on
  navigation. `mount/3` stays database-free.
  """

  use Cadence.ServerWeb, :live_view

  alias Cadence.Server.{Portfolio, PublicContent}
  alias Cadence.ServerWeb.{Metadata, Presentation}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "History",
       project: nil,
       not_found: false,
       page: 1
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    case Portfolio.get_project_by_slug(params["slug"]) do
      {:ok, project} ->
        page = Presentation.page_number(params["page"])
        path = URI.parse(uri).path || "/p/#{project.slug}/history"

        socket =
          assign(socket,
            page_title: "History · #{project.name}",
            project: project,
            page: page,
            not_found: false,
            canonical_url: Metadata.canonical(path)
          )

        {:noreply, assign_async(socket, :node_page, fn -> load_page(project, page) end)}

      {:error, :not_found} ->
        {:noreply, assign(socket, page_title: "Project not found", project: nil, not_found: true)}
    end
  end

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <article class="history-page">
      <%= if @not_found do %>
        <p class="eyebrow">404</p>
        <h1>Project not found</h1>
        <p class="note">There is no project at this address.</p>
        <p><a href="/">Back to Cadence</a></p>
      <% else %>
        <header class="project-header">
          <p class="eyebrow">History</p>
          <h1>{@project.name}</h1>
          <p class="slug">
            <a href={~p"/p/#{@project.slug}"}>Back to project</a>
          </p>
        </header>

        <section class="history-section">
          <.async_result :let={page_data} assign={@node_page}>
            <:loading>
              <p class="note">Loading history…</p>
            </:loading>

            <:failed>
              <p class="note">The commit history could not be loaded.</p>
            </:failed>

            <% current_page = Presentation.page_for(page_data.offset, page_data.limit) %>

            <p :if={page_data.total == 0} class="empty" id="history-empty">
              No commits yet.
            </p>

            <ul :if={page_data.nodes != []} class="history-list">
              <li :for={node <- page_data.nodes} id={"node-#{node.id}"} class="history-row">
                <.link
                  class="history-message"
                  navigate={~p"/p/#{@project.slug}/n/#{node.id}"}
                >
                  {node.message || "(no message)"}
                </.link>

                <span class="history-author">
                  {Presentation.import_author(node.session_metadata) || "—"}
                </span>

                <time class="history-date" datetime={DateTime.to_iso8601(node.created_at)}>
                  {Presentation.format_time(node.created_at)}
                </time>

                <.link class="history-sha" navigate={~p"/p/#{@project.slug}/n/#{node.id}"}>
                  <code>{String.slice(node.git_commit_sha, 0, 12)}</code>
                </.link>
              </li>
            </ul>

            <nav
              :if={page_data.total == 0 or page_data.has_prev or page_data.has_next}
              class="history-pager"
              aria-label="Commit history pages"
            >
              <span class="note">Page {current_page} of {page_data.total_pages}</span>

              <.link
                :if={page_data.has_prev}
                class="pager-link"
                patch={~p"/p/#{@project.slug}/history?#{[page: current_page - 1]}"}
              >
                ← Newer
              </.link>

              <.link
                :if={page_data.has_next}
                class="pager-link"
                patch={~p"/p/#{@project.slug}/history?#{[page: current_page + 1]}"}
              >
                Older →
              </.link>
            </nav>
          </.async_result>
        </section>
      <% end %>
    </article>
    """
  end

  defp load_page(project, page) do
    page_data = Portfolio.node_page(project.id, page)

    # Redaction happens on the loaded rows, inside the async task; the row in
    # the database is never mutated.
    nodes =
      Enum.map(page_data.nodes, fn node ->
        %{node | message: PublicContent.redact_message(node.message)}
      end)

    {:ok, %{node_page: %{page_data | nodes: nodes}}}
  end
end
