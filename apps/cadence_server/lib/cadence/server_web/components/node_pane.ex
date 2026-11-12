defmodule Cadence.ServerWeb.Components.NodePane do
  @moduledoc """
  The selected-node pane on the project home (spec §7.1/§7.2).

  A stateless function component: selection, quarantine, raw view, and every
  event stay with `Cadence.ServerWeb.ProjectLive`, which owns the socket. The
  pane keeps a stable `id` built from the node, the action, and a sanitized
  path (every non-alphanumeric character maps to `-`), so LiveView replaces it
  on navigation instead of patching it in place. Two paths that differ only in
  punctuation therefore share an id.
  """

  use Cadence.ServerWeb, :html

  alias Cadence.ServerWeb.Components.Repo
  alias Cadence.ServerWeb.Presentation

  attr(:project, :map, required: true)
  attr(:selected_node, :map, default: nil)
  attr(:docs_child, :map, default: nil)
  attr(:can_manage?, :boolean, default: false)
  attr(:can_pin?, :boolean, default: false)
  attr(:raw_view?, :boolean, default: false)
  attr(:quarantine, :atom, default: :ok)
  attr(:actions, :any, default: nil)
  attr(:membership, :map, default: nil)
  attr(:repo_action, :atom, default: :node)
  attr(:current_path, :string, default: "")
  attr(:tree, :map, default: nil)
  attr(:file, :map, default: nil)
  attr(:readme_html, :string, default: nil)
  attr(:readme_name, :string, default: nil)
  attr(:readme_redacted?, :boolean, default: false)
  attr(:readme_notice, :string, default: nil)
  attr(:path_error, :string, default: nil)
  attr(:pane_delay, :integer, default: 0)
  attr(:provenance, :map, default: nil)
  attr(:node_in_graph?, :boolean, default: true)
  attr(:history_page, :integer, default: nil)

  def pane(assigns) do
    ~H"""
    <section class="repo-panel reveal" style={"--pane-delay: #{@pane_delay}ms"}>
      <div
        id={pane_id(@selected_node, @repo_action, @current_path)}
        class="node-pane"
        phx-update="replace"
      >
        <%= if @selected_node do %>
          <header class="node-header">
            <p class="eyebrow">Node</p>
            <h2>{@selected_node.message || "(no message)"}</h2>
            <p :if={@provenance} class="node-provenance">{provenance_text(@provenance)}</p>
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

          <p :if={not @node_in_graph?} class="note node-outside-graph">
            This commit is older than the rendered graph.
            <.link navigate={history_path(@project, @selected_node, @history_page)}>
              Find it in History
            </.link>
          </p>

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
    """
  end

  defp pane_id(nil, _action, _path), do: "node-pane-empty"

  defp pane_id(node, action, path) do
    suffix =
      path
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_-]/, "-")

    "node-pane-#{node.id}-#{action}-#{suffix}"
  end

  # Manager-only emails are already withheld upstream by
  # `Presentation.import_provenance/2`, so the text is just the parts present.
  defp provenance_text(%{author: author, email: email}) do
    ["Imported from git" | Enum.reject([author, email], &is_nil/1)]
    |> Enum.join(" · ")
  end

  defp history_path(project, _node, nil), do: ~p"/p/#{project.slug}/history"

  defp history_path(project, node, page) do
    ~p"/p/#{project.slug}/history?#{[page: page]}" <> "#node-#{node.id}"
  end
end
