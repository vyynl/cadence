defmodule Cadence.ServerWeb.RunLive.Show do
  @moduledoc """
  One action run: status, provenance, captured output, and artifacts
  (spec §7.2, §8.3).

  Member-only, like the run list. The run is loaded through `Runs.get/3`, which
  re-checks membership and scopes the row to the project, so a run id from
  another project is indistinguishable from a missing one. Log and artifact
  readers only ever receive that checked row.

  Output is rendered as text inside a `<pre>`: ANSI/control sequences are
  stripped and HTML is escaped by HEEx. `raw/1` is never used.

  ## Artifact paging

  The collector produces at most 1,000 files and the page loads that whole list
  (it is how the links are built), then slices 100 per page under
  `?artifacts_page=N`. Because the list is already in memory, an out-of-range
  page is clamped to the last one instead of rendering an empty page. Paging is
  presentational: it bounds the DOM, not the directory read.

  Once connected, a `{:action_run_updated, …}` for this run reloads the page at
  the current artifact page; the status events are ids-only and logs arrive only
  after the container exits.
  """

  use Cadence.ServerWeb, :live_view

  alias Cadence.Server.Actions
  alias Cadence.Server.Actions.Runs
  alias Cadence.Server.ActionRun
  alias Cadence.ServerWeb.{Presentation, ReviewAccess}

  @artifact_page_size 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Run",
       project: nil,
       run_id: nil,
       not_found: false,
       artifacts_page: 1,
       subscribed_project_id: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case ReviewAccess.authorize(socket.assigns[:current_user], params["slug"]) do
      {:ok, project, _membership} ->
        if Actions.enabled?() do
          run_id = params["run_id"]
          user_id = socket.assigns.current_user.id
          artifacts_page = Presentation.page_number(params["artifacts_page"])

          socket =
            socket
            |> maybe_subscribe(project)
            |> assign(
              page_title: "Run · #{project.name}",
              project: project,
              run_id: run_id,
              artifacts_page: artifacts_page,
              not_found: false
            )

          {:noreply,
           assign_async(socket, :run_state, fn -> load_run(project, user_id, run_id) end)}
        else
          {:noreply,
           socket
           |> put_flash(:error, "Action runs are disabled for this deployment.")
           |> push_navigate(to: ~p"/p/#{project.slug}")}
        end

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, "Only project members can see action runs.")
         |> push_navigate(to: ~p"/p/#{params["slug"]}")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> unsubscribe()
         |> assign(page_title: "Project not found", project: nil, not_found: true)}
    end
  end

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:action_run_updated, project_id, run_id, _status}, socket) do
    case {socket.assigns.project, socket.assigns.run_id} do
      {%{id: ^project_id} = project, ^run_id} when not is_nil(run_id) ->
        user_id = socket.assigns.current_user.id

        {:noreply, assign_async(socket, :run_state, fn -> load_run(project, user_id, run_id) end)}

      _other ->
        {:noreply, socket}
    end
  end

  # Other project events cannot change this run.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <article class="run-page">
      <%= if @not_found do %>
        <p class="eyebrow">404</p>
        <h1>Project not found</h1>
        <p class="note">There is no project at this address.</p>
        <p><a href="/">Back to Cadence</a></p>
      <% else %>
        <header class="project-header">
          <p class="eyebrow">Action run</p>
          <h1>{@project.name}</h1>
          <p class="slug">
            <a href={~p"/p/#{@project.slug}"}>Back to project</a>
            <a href={~p"/p/#{@project.slug}/runs"}>All runs</a>
          </p>
        </header>

        <.async_result :let={payload} assign={@run_state}>
          <:loading>
            <p class="note">Loading run…</p>
          </:loading>

          <:failed>
            <p class="note">This run was not found in this project.</p>
            <p><a href={~p"/p/#{@project.slug}/runs"}>Back to runs</a></p>
          </:failed>

          <section class="run-detail">
            <% {shown_artifacts, artifact_page, artifact_pages} =
              artifact_slice(payload.artifacts, @artifacts_page) %>

            <div class="run-detail-heading">
              <h2>{payload.run.action_name}</h2>
              <span class={Presentation.run_status_class(payload.run.status)}>
                {Presentation.run_status_label(payload.run.status)}
              </span>
            </div>

            <p :if={payload.run.status == :queued} class="note">
              Queued: the run starts when this project has a free action slot.
            </p>

            <p :if={payload.run.status == :running} class="note">
              The action is running. Output is captured when the container exits.
            </p>

            <p :if={Presentation.run_error_label(payload.run.error_reason)} class="run-error">
              {Presentation.run_error_label(payload.run.error_reason)}
            </p>

            <dl class="run-meta">
              <dt>Node</dt>
              <dd>
                <.link navigate={~p"/p/#{@project.slug}/n/#{payload.run.node_id}"}>
                  {String.slice(payload.run.node_id, 0, 8)}
                </.link>
              </dd>

              <dt>Command</dt>
              <dd><code>{payload.run.command}</code></dd>

              <dt :if={payload.run.image}>Image</dt>
              <dd :if={payload.run.image}><code>{payload.run.image}</code></dd>

              <dt :if={payload.run.started_at}>Started</dt>
              <dd :if={payload.run.started_at}>
                {Presentation.format_time(payload.run.started_at)}
              </dd>

              <dt :if={payload.run.finished_at}>Finished</dt>
              <dd :if={payload.run.finished_at}>
                {Presentation.format_time(payload.run.finished_at)}
              </dd>

              <dt
                :if={Presentation.run_duration(payload.run.started_at, payload.run.finished_at)}
              >
                Duration
              </dt>
              <dd
                :if={Presentation.run_duration(payload.run.started_at, payload.run.finished_at)}
              >
                {Presentation.run_duration(payload.run.started_at, payload.run.finished_at)}
              </dd>

              <dt :if={is_integer(payload.run.exit_code)}>Exit code</dt>
              <dd :if={is_integer(payload.run.exit_code)}>{payload.run.exit_code}</dd>
            </dl>

            <section class="run-output" aria-label="Run output">
              <h3>Output</h3>
              <% terminal? = ActionRun.terminal?(payload.run.status) %>

              <p :if={payload.log in [nil, ""] and terminal?} class="note">
                No output was captured.
              </p>
              <p :if={payload.log in [nil, ""] and not terminal?} class="note">
                Output will appear when the run finishes.
              </p>
              <pre :if={payload.log not in [nil, ""]} class="run-log">{payload.log}</pre>
            </section>

            <section class="run-artifacts" aria-label="Run artifacts">
              <h3>Artifacts</h3>

              <p :if={payload.run.artifact_error} class="note">
                Artifacts were not collected. The run status is unaffected.
              </p>

              <p
                :if={
                  payload.artifacts == [] and is_nil(payload.run.artifact_error) and terminal?
                }
                class="note"
              >
                No artifacts were produced.
              </p>

              <p
                :if={
                  payload.artifacts == [] and is_nil(payload.run.artifact_error) and
                    not terminal?
                }
                class="note"
              >
                Artifacts will appear when the run finishes.
              </p>

              <ul :if={shown_artifacts != []} class="artifact-list">
                <li :for={artifact <- shown_artifacts} class="artifact-row">
                  <a
                    href={artifact_href(@project.slug, payload.run.id, artifact.path)}
                    download
                  >
                    {artifact.path}
                  </a>
                  <span class="note">{format_size(artifact.size)}</span>
                </li>
              </ul>

              <p :if={artifact_pages > 1} class="note">
                Page {artifact_page} of {artifact_pages} · {length(payload.artifacts)} artifacts
              </p>

              <nav
                :if={artifact_pages > 1}
                class="run-pager"
                aria-label="Artifact pages"
              >
                <.link
                  :if={artifact_page > 1}
                  class="pager-link"
                  patch={
                    ~p"/p/#{@project.slug}/runs/#{payload.run.id}?#{[artifacts_page: artifact_page - 1]}"
                  }
                >
                  ← Previous artifacts
                </.link>

                <.link
                  :if={artifact_page < artifact_pages}
                  class="pager-link"
                  patch={
                    ~p"/p/#{@project.slug}/runs/#{payload.run.id}?#{[artifacts_page: artifact_page + 1]}"
                  }
                >
                  More artifacts →
                </.link>
              </nav>
            </section>
          </section>
        </.async_result>
      <% end %>
    </article>
    """
  end

  defp load_run(project, user_id, run_id) do
    with {:ok, run} <- Runs.get(%{id: user_id}, project.id, run_id) do
      {:ok,
       %{
         run_state: %{
           run: run,
           log: read_log(run),
           artifacts: Runs.artifacts(run)
         }
       }}
    else
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp read_log(run) do
    case Runs.log(run) do
      {:ok, content} -> Presentation.terminal_text(content)
      {:error, :not_found} -> nil
    end
  end

  # The whole collected set is already loaded, so a requested page past the end
  # is corrected here rather than rendered as an empty artifact list.
  defp artifact_slice(artifacts, requested) do
    pages = max(div(length(artifacts) + @artifact_page_size - 1, @artifact_page_size), 1)
    current = min(max(requested, 1), pages)
    start = (current - 1) * @artifact_page_size

    {Enum.slice(artifacts, start, @artifact_page_size), current, pages}
  end

  # Artifact relative paths can contain spaces or `#`; encode each segment so
  # the `*path` route receives exactly the stored name.
  defp artifact_href(slug, run_id, relative) do
    encoded = relative |> String.split("/") |> Enum.map_join("/", &URI.encode/1)

    "/p/#{URI.encode(slug)}/runs/#{run_id}/artifacts/#{encoded}"
  end

  defp format_size(bytes) when is_integer(bytes) and bytes < 1_024, do: "#{bytes} B"

  defp format_size(bytes) when is_integer(bytes) and bytes < 1_048_576,
    do: "#{Float.round(bytes / 1_024, 1)} KiB"

  defp format_size(bytes) when is_integer(bytes),
    do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  defp format_size(_bytes), do: "0 B"

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
end
