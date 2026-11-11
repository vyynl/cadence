defmodule Cadence.ServerWeb.Components.Repo do
  @moduledoc """
  Server-rendered repository browser pieces: breadcrumbs, tree, file view,
  README, and the quarantine notice.
  """

  use Cadence.ServerWeb, :html

  attr(:project_slug, :string, required: true)
  attr(:node_id, :string, required: true)
  attr(:current_path, :string, default: "")

  def breadcrumbs(assigns) do
    assigns = assign(assigns, :segments, path_segments(assigns.current_path))

    ~H"""
    <nav class="breadcrumbs" aria-label="Breadcrumb">
      <.link patch={node_home(@project_slug, @node_id)}>root</.link>
      <span :for={{segment, index} <- Enum.with_index(@segments, 1)}>
        <span class="crumb-sep">/</span>
        <.link
          :if={index < length(@segments)}
          patch={tree_path(@project_slug, @node_id, @segments |> Enum.take(index) |> Enum.join("/"))}
        >
          {segment}
        </.link>
        <span :if={index == length(@segments)}>{segment}</span>
      </span>
    </nav>
    """
  end

  attr(:entries, :list, required: true)
  attr(:hidden_count, :integer, default: 0)
  attr(:truncated?, :boolean, default: false)
  attr(:project_slug, :string, required: true)
  attr(:node_id, :string, required: true)
  attr(:current_path, :string, default: "")

  def tree(assigns) do
    ~H"""
    <div class="repo-tree">
      <.breadcrumbs
        project_slug={@project_slug}
        node_id={@node_id}
        current_path={@current_path}
      />

      <ul class="file-tree">
        <li :for={entry <- @entries}>
          <.link
            :if={entry.type != :commit}
            patch={entry_path(@project_slug, @node_id, entry)}
            class="file-row"
          >
            <span class="file-kind">{entry_kind(entry.type)}</span>
            <span class="file-name">{entry.name}</span>
          </.link>
          <span :if={entry.type == :commit} class="file-row">
            <span class="file-kind">{entry_kind(entry.type)}</span>
            <span class="file-name">{entry.name}</span>
          </span>
        </li>
      </ul>

      <p :if={@entries == []} class="note">This directory is empty.</p>
      <p :if={@hidden_count > 0} class="note">
        {@hidden_count} {if @hidden_count == 1, do: "entry", else: "entries"} hidden for security.
      </p>
      <p :if={@truncated?} class="note">Directory listing truncated.</p>
    </div>
    """
  end

  attr(:file, :map, required: true)
  attr(:project_slug, :string, required: true)
  attr(:node_id, :string, required: true)

  def file(assigns) do
    ~H"""
    <div class="file-view">
      <.breadcrumbs
        project_slug={@project_slug}
        node_id={@node_id}
        current_path={@file.path}
      />

      <p class="file-meta">
        <span>{@file.path}</span>
        <span :if={@file.redacted?}>Some values were redacted for security.</span>
      </p>

      <p :if={@file.binary?} class="note">Binary file not shown.</p>
      <p :if={@file.truncated? and is_nil(@file.content)} class="note">
        File too large to display.
      </p>
      <p :if={@file.truncated? and @file.content} class="note">
        File truncated for display.
      </p>

      <div :if={@file.content} class="file-lines">
        <div
          :for={{line, index} <- Enum.with_index(String.split(@file.content, "\n"), 1)}
          class="file-line"
        >
          <span class="line-number">{index}</span>
          <span class="line-text">{line}</span>
        </div>
      </div>
    </div>
    """
  end

  attr(:html, :string, required: true)
  attr(:name, :string, default: nil)
  attr(:redacted?, :boolean, default: false)

  def readme(assigns) do
    ~H"""
    <section class="readme">
      <p :if={@redacted?} class="note">Some values were redacted for security.</p>
      <div class="markdown">{raw(@html)}</div>
    </section>
    """
  end

  attr(:eyebrow, :string, default: "Protected snapshot")
  attr(:title, :string, default: "Snapshot hidden for review")

  attr(:body, :string,
    default: "This node's repository is hidden while it is reviewed for sensitive content."
  )

  def quarantine(assigns) do
    ~H"""
    <div class="quarantine-notice callout callout-protected">
      <p class="eyebrow">{@eyebrow}</p>
      <h2>{@title}</h2>
      <p class="note">{@body}</p>
    </div>
    """
  end

  defp path_segments(nil), do: []
  defp path_segments(""), do: []
  defp path_segments(path), do: String.split(path, "/", trim: true)

  defp entry_kind(:tree), do: "dir"
  defp entry_kind(:blob), do: "file"
  defp entry_kind(:commit), do: "submodule"

  defp entry_path(project_slug, node_id, %{type: :tree, path: path}) do
    tree_path(project_slug, node_id, path)
  end

  defp entry_path(project_slug, node_id, %{type: :blob, path: path}) do
    blob_path(project_slug, node_id, path)
  end

  defp node_home(project_slug, node_id), do: "/p/#{project_slug}/n/#{node_id}"

  defp tree_path(project_slug, node_id, path) do
    "/p/#{project_slug}/n/#{node_id}/tree/" <> encode_path(path)
  end

  defp blob_path(project_slug, node_id, path) do
    "/p/#{project_slug}/n/#{node_id}/blob/" <> encode_path(path)
  end

  defp encode_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map_join("/", &URI.encode/1)
  end
end
