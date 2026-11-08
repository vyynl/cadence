defmodule Cadence.Server.Actions.Cleanup do
  @moduledoc """
  Retention for action logs, artifacts, and built images (spec §8.3).

  One pass is elected by a global advisory lock, then the two independent
  policies run:

  - **Artifacts/logs are age-based.** A terminal run older than
    `CAD_ACTIONS_ARTIFACT_RETENTION_DAYS` (`0` disables) has its
    `<CAD_ARTIFACT_PATH>/<run_id>/` directory removed and its `log_path`/
    `artifact_path` nulled. The row, status, exit code, and `artifact_error`
    survive, so the run history stays honest. Only terminal runs are touched: a
    queued/running run has no finished artifacts to remove.
  - **Images are keep-newest-N per project.** `cadence-action-<slug>-<sha12>`
    tags are grouped by the stored project slug prefix and only the newest
    `CAD_ACTIONS_IMAGE_RETENTION_PER_PROJECT` (`0` disables) are kept. A pruned
    image is not a correctness problem: the runner rebuilds on
    `image? == false`.

  Runs are capped by `CAD_ACTIONS_RETENTION_BATCH` so one pass stays bounded; a
  sweep with more eligible rows continues on the next pass. A `File.rm_rf`
  failure keeps the row's paths so the next pass retries. Every failure is
  shape-only logged and never raised; Docker being unavailable only skips the
  image half.

  The lock is transaction-scoped (`pg_try_advisory_xact_lock`), so a crashed
  sweep cannot leave it held on a pooled connection. It covers the artifact
  sweep; the elected pass then prunes images **after** the transaction commits,
  so a slow Docker proxy never holds a Repo connection. A busy result is a
  **skip**, not a failure: deletion is idempotent, and a later pass retries.
  """

  import Ecto.Query

  require Logger

  alias Cadence.Server.{ActionRun, Repo}
  alias Cadence.Server.Actions
  alias Cadence.Server.Actions.Docker
  alias Cadence.Shared.Project

  # Global cleanup lock (no project dimension: the batch spans projects).
  @cleanup_lock_sql "SELECT pg_try_advisory_xact_lock(hashtext('cadence.actions_cleanup'))"

  @doc """
  Run one cleanup pass (artifacts/logs, then images) under the global lock.

  Returns `{:ok, %{artifacts: stats, images: stats}}`, `{:error, :busy}` when
  another pass holds the lock, or `{:error, :failed}` if the pass crashed.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, :busy | :failed}
  def run(opts \\ []) do
    elected =
      Repo.transaction(fn ->
        if cleanup_lock?(), do: sweep(opts), else: :busy
      end)

    case elected do
      {:ok, :busy} ->
        {:error, :busy}

      {:ok, artifacts} ->
        # The lock is released now; image pruning is idempotent, so the worst
        # case of a late overlapping pass is duplicate 404-tolerant removals.
        {:ok, %{artifacts: artifacts, images: prune_images(opts)}}

      {:error, _reason} ->
        {:error, :failed}
    end
  rescue
    error ->
      Logger.warning("action cleanup skipped: #{shape(error)}")
      {:error, :failed}
  catch
    kind, reason ->
      Logger.warning("action cleanup exited: #{inspect(kind)}/#{shape(reason)}")
      {:error, :failed}
  end

  @doc """
  Delete logs/artifacts for terminal runs older than the retention window.

  Options: `:days` (default `Actions.artifact_retention_days/0`) and `:batch`
  (default `Actions.retention_batch/0`). A non-positive `:days` disables the
  sweep. Safe to call directly (tests/manual tooling).
  """
  @spec sweep(keyword()) :: %{swept: non_neg_integer(), failed: non_neg_integer()}
  def sweep(opts \\ []) do
    days = Keyword.get(opts, :days, Actions.artifact_retention_days())
    batch = Keyword.get(opts, :batch, Actions.retention_batch())

    if is_integer(days) and days > 0 and is_integer(batch) and batch > 0 do
      cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

      from(r in ActionRun,
        where:
          r.status in ^ActionRun.terminal_statuses() and r.updated_at < ^cutoff and
            (not is_nil(r.log_path) or not is_nil(r.artifact_path)),
        order_by: [asc: r.updated_at, asc: r.id],
        limit: ^batch
      )
      |> Repo.all()
      |> Enum.reduce(%{swept: 0, failed: 0}, &sweep_run/2)
    else
      %{swept: 0, failed: 0}
    end
  end

  @doc """
  Remove `cadence-action-*` images beyond the per-project keep count.

  Options: `:keep_images` (default `Actions.image_retention_per_project/0`);
  `0` disables image pruning. Only tags that match a stored project slug are
  considered, so unrelated images and images from removed projects are left
  alone.
  """
  @spec prune_images(keyword()) :: %{
          removed: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def prune_images(opts \\ []) do
    keep = Keyword.get(opts, :keep_images, Actions.image_retention_per_project())

    if Actions.enabled?() and is_integer(keep) and keep > 0 do
      case list_images() do
        {:ok, images} ->
          prefixes = project_prefixes()

          images
          |> group_by_prefix(prefixes)
          |> Enum.reduce(%{removed: 0, failed: 0}, fn {_prefix, tagged}, acc ->
            tagged
            |> Enum.sort_by(& &1.created_at, :desc)
            |> Enum.drop(keep)
            |> Enum.reduce(acc, &remove_tag/2)
          end)

        {:error, reason} ->
          Logger.warning("action image cleanup skipped: #{shape(reason)}")
          %{removed: 0, failed: 0}
      end
    else
      %{removed: 0, failed: 0}
    end
  end

  ## Internals

  defp cleanup_lock? do
    case Repo.query!(@cleanup_lock_sql) do
      %{rows: [[true]]} -> true
      _other -> false
    end
  end

  defp sweep_run(run, acc) do
    case File.rm_rf(Path.join(Actions.artifact_path(), run.id)) do
      {:ok, _removed} ->
        from(r in ActionRun, where: r.id == ^run.id)
        |> Repo.update_all(set: [log_path: nil, artifact_path: nil])

        %{acc | swept: acc.swept + 1}

      {:error, reason, _path} ->
        Logger.warning("action artifact cleanup skipped run=#{run.id} reason=#{shape(reason)}")

        %{acc | failed: acc.failed + 1}
    end
  rescue
    error ->
      Logger.warning("action artifact cleanup crashed run=#{run.id}: #{shape(error)}")
      %{acc | failed: acc.failed + 1}
  end

  defp list_images do
    Docker.impl().list_images()
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp project_prefixes do
    from(p in Project, select: p.slug)
    |> Repo.all()
    |> Enum.map(&image_prefix/1)
    |> Enum.uniq()
  end

  # Must match `Runs.image_tag/2`: Docker references are capped at 255 chars,
  # so the slug is sliced to 40.
  defp image_prefix(slug), do: "cadence-action-#{String.slice(to_string(slug), 0, 40)}-"

  defp group_by_prefix(images, prefixes) do
    Enum.reduce(images, %{}, fn image, acc ->
      Enum.reduce(image.tags, acc, fn tag, acc ->
        case matching_prefix(tag, prefixes) do
          nil ->
            acc

          prefix ->
            entry = %{tag: tag, created_at: image.created_at}
            Map.update(acc, prefix, [entry], &[entry | &1])
        end
      end)
    end)
  end

  # Slugs may prefix one another (`cleanup` vs `cleanup-other`), so the longest
  # match owns the tag; otherwise the shorter project would prune the other's
  # newest image.
  defp matching_prefix(tag, prefixes) do
    matches = Enum.filter(prefixes, &String.starts_with?(tag, &1))

    case matches do
      [] -> nil
      matches -> Enum.max_by(matches, &byte_size/1)
    end
  end

  defp remove_tag(%{tag: tag}, acc) do
    case Docker.impl().remove_image(tag) do
      :ok ->
        %{acc | removed: acc.removed + 1}

      {:error, reason} ->
        Logger.warning("action image removal skipped tag=#{tag} reason=#{shape(reason)}")
        %{acc | failed: acc.failed + 1}
    end
  rescue
    error ->
      Logger.warning("action image removal crashed: #{shape(error)}")
      %{acc | failed: acc.failed + 1}
  end

  # Failure reasons may be raw terms from an adapter; log only the shape.
  defp shape(%{__struct__: module}), do: inspect(module)
  defp shape(term) when is_atom(term), do: Atom.to_string(term)
  defp shape(term) when is_tuple(term), do: "tuple/#{tuple_size(term)}"
  defp shape(_term), do: "term"
end
