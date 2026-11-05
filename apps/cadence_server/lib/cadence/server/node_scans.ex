defmodule Cadence.Server.NodeScans do
  @moduledoc """
  Scans pushed node snapshots and records isolation incidents (spec §6.7).

  The scan runs **after** the push transaction commits, so a failed scan can
  never roll back a successful push. Only nodes inserted by the current push are
  scanned: existing nodes are immutable and were scanned when first inserted.

  Every scan is bounded by `Cadence.Server.Portfolio.scan_limits/0` (the same
  caps the public read path uses). A snapshot that cannot be fully walked is
  reported as `scan_incomplete` (critical), never treated as safe. `details`
  carries pattern names and counts only — never secret values or file content.

  Scanning is best-effort alerting, not part of transport success: every
  function returns `:ok`, even when the incident insert itself fails.
  """

  alias Cadence.Server.{Incidents, Portfolio, ProjectGit, PublicContent}
  alias Cadence.Shared.{GitStore, Node}

  @doc """
  Scans every node in `nodes` for `project_id`, recording incidents per node.

  Nodes are scanned independently: one failing scan never halts the batch.
  Always returns `:ok`.
  """
  @spec scan_nodes(Ecto.UUID.t(), [Node.t()]) :: :ok
  def scan_nodes(project_id, nodes) when is_list(nodes) do
    Enum.each(nodes, &scan_node(project_id, &1))
    :ok
  end

  @doc """
  Scans one pushed snapshot and opens the matching incident, if any.

  Secret findings and cap overflows are critical; unreadable snapshots are high.
  A clean snapshot opens nothing. Always returns `:ok`.
  """
  @spec scan_node(Ecto.UUID.t(), Node.t()) :: :ok
  def scan_node(project_id, %Node{} = node) do
    %{max_files: max_files, max_bytes: max_bytes} = Portfolio.scan_limits()

    result =
      try do
        GitStore.walk_blobs(ProjectGit.open(project_id), node.git_commit_sha,
          max_files: max_files,
          max_bytes: max_bytes
        )
      rescue
        # A corrupt store must not fail the push; report it as unreadable.
        _error -> {:error, :scan_failed}
      end

    case result do
      {:ok, blobs} -> record_findings(project_id, node, blobs)
      {:error, reason} -> record_failure(project_id, node, reason)
    end

    :ok
  end

  defp record_findings(project_id, node, blobs) do
    if PublicContent.quarantine?(blobs) do
      open_incident(
        project_id,
        node,
        :secret_detected,
        :critical,
        "Secret detected in pushed snapshot",
        %{
          stage: :push_scan,
          patterns: patterns(blobs),
          sensitive_paths: sensitive_paths(blobs)
        }
      )
    end

    :ok
  end

  defp record_failure(project_id, node, reason)
       when reason in [:too_many_files, :too_many_bytes] do
    open_incident(
      project_id,
      node,
      :scan_incomplete,
      :critical,
      "Push scan incomplete",
      %{stage: :push_scan, reason: reason}
    )
  end

  defp record_failure(project_id, node, reason) do
    open_incident(
      project_id,
      node,
      :missing_objects,
      :high,
      "Pushed snapshot is unreadable",
      %{stage: :push_scan, reason: scan_reason(reason)}
    )
  end

  defp patterns(blobs) do
    blobs
    |> Enum.flat_map(&PublicContent.findings(&1.content))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp sensitive_paths(blobs) do
    Enum.count(blobs, fn %{path: path} ->
      PublicContent.sensitive_path?(path) and not PublicContent.allowed_sensitive_path?(path)
    end)
  end

  defp open_incident(project_id, node, kind, severity, title, details) do
    _ =
      Incidents.open(%{
        project_id: project_id,
        node_id: node.id,
        kind: kind,
        severity: severity,
        title: title,
        details: details
      })

    :ok
  rescue
    # Alerting is best-effort: a failed insert leaves the push successful and
    # the read-path scan still quarantines risky content.
    _error -> :ok
  end

  defp scan_reason(reason) when is_atom(reason), do: reason
  defp scan_reason(_reason), do: :unknown
end
