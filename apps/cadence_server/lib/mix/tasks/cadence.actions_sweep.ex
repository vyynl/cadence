defmodule Mix.Tasks.Cadence.ActionsSweep do
  @shortdoc "Remove expired action logs/artifacts and old action images"

  @moduledoc """
  Runs one action-retention pass (spec §8.3).

      mix cadence.actions_sweep [--days N] [--keep-images N]

  Artifacts/logs of terminal runs older than `--days` (default
  `CAD_ACTIONS_ARTIFACT_RETENTION_DAYS`) are removed; the run row keeps its
  status and history with `log_path`/`artifact_path` nulled. `cadence-action-*`
  images beyond `--keep-images` per project (default
  `CAD_ACTIONS_IMAGE_RETENTION_PER_PROJECT`) are removed as well. A value of
  `0` disables the corresponding half of the pass.

  This task is `mix`-only. It never binds the HTTP port, so it is safe inside an
  already-running container (`docker compose exec server mix
  cadence.actions_sweep`). A periodic backstop runs the same pass every
  `CAD_ACTIONS_RETENTION_INTERVAL_MS` unless that is `0`.
  """

  use Mix.Task

  alias Cadence.Server.Actions.Cleanup

  @impl true
  def run(argv) do
    Mix.Task.run("app.config")

    {opts, args, invalid} =
      OptionParser.parse(argv, strict: [days: :integer, keep_images: :integer])

    if invalid != [] or args != [] do
      Mix.raise("usage: mix cadence.actions_sweep [--days N] [--keep-images N]")
    end

    start_app()

    case Cleanup.run(opts) do
      {:ok, %{artifacts: artifacts, images: images}} ->
        Mix.shell().info(
          "artifacts: swept=#{artifacts.swept} failed=#{artifacts.failed}; " <>
            "images: removed=#{images.removed} failed=#{images.failed}"
        )

      {:error, :busy} ->
        Mix.raise("another action cleanup pass is running")

      {:error, :failed} ->
        Mix.raise("action cleanup failed; see the log")
    end
  end

  defp start_app do
    # Repo and the action children are all a pass needs; never bind the port.
    # A maintenance task must not drain the run queue as a side effect (the
    # Dispatcher's boot pass is disabled for this process only).
    Application.put_env(:cadence_server, :actions_dispatch_on_boot, false)
    endpoint_config = Application.get_env(:cadence_server, Cadence.ServerWeb.Endpoint, [])

    Application.put_env(
      :cadence_server,
      Cadence.ServerWeb.Endpoint,
      Keyword.put(endpoint_config, :server, false)
    )

    case Application.ensure_all_started(:cadence_server) do
      {:ok, _apps} -> :ok
      {:error, reason} -> Mix.raise("could not start cadence_server: #{inspect(reason)}")
    end
  end
end
