defmodule Mix.Tasks.Cad.Import do
  use Mix.Task

  alias Cadence.Daemon.ImportClient

  @shortdoc "Import a local Git repository: mix cad.import PATH [options]"

  @moduledoc """
  Imports a local Git repository into a Cadence project through the running
  daemon's Unix socket (spec §5.7).

      mix cad.import ~/code/thing
      mix cad.import ~/code/thing --ref release --all-refs --allow-shallow
      mix cad.import ~/code/thing --name "Thing" --slug thing --limit 500

  The project is created when the source is not registered yet, then the
  history is imported as one node per commit and queued for sync. The command
  polls until the job finishes and prints the summary; `--json` prints the
  final job instead.

  `--limit N` is a maximum: a history with more than N commits is rejected
  (the effective cap is the smaller of N and `CAD_IMPORT_MAX_COMMITS`).
  """

  @switches [
    name: :string,
    slug: :string,
    ref: :keep,
    all_refs: :boolean,
    allow_shallow: :boolean,
    limit: :integer,
    project: :string,
    json: :boolean
  ]

  @aliases [r: :ref]

  @impl Mix.Task
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    case argv do
      [path] ->
        run_import(path, opts)

      _other ->
        Mix.raise(
          "usage: mix cad.import PATH [--name NAME] [--slug SLUG] [--ref REF] [--all-refs] " <>
            "[--allow-shallow] [--limit N] [--project ID] [--json]"
        )
    end
  end

  defp run_import(path, opts) do
    attrs =
      ImportClient.attrs(path,
        refs: Keyword.get_values(opts, :ref),
        all_refs: opts[:all_refs],
        allow_shallow: opts[:allow_shallow],
        limit: opts[:limit],
        project_id: opts[:project],
        name: opts[:name],
        slug: opts[:slug]
      )

    case ImportClient.start(attrs) do
      {:ok, job} ->
        Mix.shell().info(
          "import #{job["id"]} queued for #{job["project_slug"]} " <>
            "(#{job["total"]} commits, refs: #{Enum.join(job["refs"], ", ")})"
        )

        case ImportClient.wait(job["id"]) do
          {:ok, final} -> report(final, opts[:json])
          {:error, :timeout} -> Mix.raise("import #{job["id"]} did not finish in time")
          {:error, {status, message}} -> Mix.raise("import status failed (#{status}): #{message}")
        end

      {:error, {status, message}} ->
        Mix.raise("import rejected (#{status}): #{message}")
    end
  end

  defp report(job, nil), do: report(job, false)

  defp report(job, true) do
    Mix.shell().info(Jason.encode!(job, pretty: true))
  end

  defp report(%{"status" => "completed"} = job, false) do
    Mix.shell().info(
      "import #{job["id"]} completed: #{job["imported"]} imported, " <>
        "#{job["reused"]} already present, #{job["objects"]} objects " <>
        "(#{job["bytes"]} bytes), tip #{short(job["tip_node_id"])}"
    )

    if job["merge_commits"] > 0 do
      Mix.shell().info(
        "#{job["merge_commits"]} merge commit(s) will not publish until the server " <>
          "accepts multi-parent pushes (Phase 9c); their descendants stay queued."
      )
    end
  end

  defp report(%{"status" => "failed"} = job, false) do
    error = job["error"] || %{}
    Mix.raise("import #{job["id"]} failed: #{error["code"]}: #{error["message"]}")
  end

  defp report(job, false) do
    Mix.shell().info("import #{job["id"]} is #{job["status"]}")
  end

  defp short(nil), do: "-"
  defp short(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8)
  defp short(id), do: to_string(id)
end
