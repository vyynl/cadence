defmodule Cadence.ServerWeb.RunLive.Index do
  @moduledoc """
  Member-only action run history for a project (spec §7.2, §8.3).

  The list is project-scoped and newest first. It is the traceable entry point
  from a run back to the immutable snapshot it executed: every row links the
  node that triggered it and the run detail page.

  ## Freshness

  Authorization runs in `handle_params/3` because a refused visitor must be
  redirected, and an `assign_async` failure cannot navigate. `mount/3` stays
  database-free. Once connected, the socket subscribes to `project:<id>` and a
  `{:action_run_updated, …}` reloads the list. Events are ids only; logs and
  commands never travel over PubSub.
  """

  use Cadence.ServerWeb, :live_view

  alias Cadence.Server.Actions
  alias Cadence.Server.Actions.Runs
  alias Cadence.ServerWeb.{Presentation, ReviewAccess}

  @limit 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Runs",
       project: nil,
       not_found: false,
       limit: @limit,
       subscribed_project_id: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case ReviewAccess.authorize(socket.assigns[:current_user], params["slug"]) do
      {:ok, project, _membership} ->
        if Actions.enabled?() do
          user_id = socket.assigns.current_user.id

          socket =
            socket
            |> maybe_subscribe(project)
            |> assign(
              page_title: "Runs · #{project.name}",
              project: project,
              not_found: false
            )

          {:noreply, assign_async(socket, :runs, fn -> load_runs(project, user_id) end)}
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
  def handle_info({:action_run_updated, project_id, _run_id, _status}, socket) do
    case socket.assigns.project do
      %{id: ^project_id} = project ->
        user_id = socket.assigns.current_user.id
        {:noreply, assign_async(socket, :runs, fn -> load_runs(project, user_id) end)}

      _other ->
        {:noreply, socket}
    end
  end

  # This socket also receives proposal/incident/push/preference events; none of
  # them can change the run list.
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
          <p class="eyebrow">Action runs</p>
          <h1>{@project.name}</h1>
          <p class="slug">
            <a href={~p"/p/#{@project.slug}"}>Back to project</a>
          </p>
        </header>

        <section class="run-queue">
          <div class="panel-heading">
            <h2>Runs</h2>
          </div>

          <.async_result :let={runs} assign={@runs}>
            <:loading>
              <p class="note">Loading runs…</p>
            </:loading>

            <:failed>
              <p class="note">The run list could not be loaded.</p>
            </:failed>

            <p :if={runs == []} class="empty">No action runs yet.</p>

            <ul :if={runs != []} class="run-list">
              <li :for={run <- runs} id={"run-#{run.id}"} class="run-row">
                <span class={Presentation.run_status_class(run.status)}>
                  {Presentation.run_status_label(run.status)}
                </span>

                <.link class="file-name" navigate={~p"/p/#{@project.slug}/runs/#{run.id}"}>
                  {run.action_name}
                </.link>

                <.link class="note" navigate={~p"/p/#{@project.slug}/n/#{run.node_id}"}>
                  node {String.slice(run.node_id, 0, 8)}
                </.link>

                <span :if={is_integer(run.exit_code)} class="note">exit {run.exit_code}</span>

                <span :if={Presentation.run_duration(run.started_at, run.finished_at)} class="note">
                  {Presentation.run_duration(run.started_at, run.finished_at)}
                </span>

                <span :if={run.created_at} class="note">
                  <time datetime={DateTime.to_iso8601(run.created_at)}>
                    {Presentation.age(run.created_at)}
                  </time>
                </span>
              </li>
            </ul>

            <p :if={length(runs) >= @limit} class="note">
              Showing the {@limit} newest runs.
            </p>
          </.async_result>
        </section>
      <% end %>
    </article>
    """
  end

  defp load_runs(project, user_id) do
    case Runs.list(%{id: user_id}, project.id, limit: @limit) do
      {:ok, runs} -> {:ok, %{runs: runs}}
      {:error, _reason} -> {:error, :not_loaded}
    end
  end

  # The project id is only known once the slug resolves, so subscription
  # happens in `handle_params/3`, never `mount/3`.
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
