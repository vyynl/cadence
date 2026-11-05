defmodule Mix.Tasks.Cadence.DemoSeed do
  @shortdoc "Seed the browsable demo projects and accounts"

  @moduledoc """
  Seeds the demo dataset used by the local demo stack (spec §12.4).

      mix cadence.demo_seed [--reset]

  Idempotent: a second run without `--reset` leaves the data alone. `--reset`
  deletes the demo projects, their rows and Git stores, and the demo users
  before rebuilding.

  This task is `mix`-only. It is never registered as an HTTP route.
  """

  use Mix.Task

  alias Cadence.Server.DemoSeed

  @impl true
  def run(argv) do
    Mix.Task.run("app.config")

    {opts, _args, invalid} =
      OptionParser.parse(argv, strict: [reset: :boolean], aliases: [r: :reset])

    if invalid != [] do
      Mix.raise("unknown option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    # Repo and PubSub are all the seed needs. Never bind the HTTP port, so the
    # task is safe to run inside an already-running container
    # (`docker compose exec server mix cadence.demo_seed --reset`).
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

    summary = DemoSeed.run(opts)
    print_summary(summary)
  end

  defp print_summary(summary) do
    shell = Mix.shell()
    base = String.trim_trailing(summary.public_url || "http://localhost:4000", "/")

    shell.info("Demo data ready (fresh: #{summary.fresh})")
    shell.info("")
    shell.info("Password for every demo account: #{summary.password}")
    shell.info("")
    shell.info("Accounts:")

    Enum.each(summary.users, fn user ->
      shell.info("  #{user.email} (#{user.name})")
    end)

    shell.info("")
    shell.info("Projects:")

    Enum.each(summary.projects, fn project ->
      shell.info("  #{project.name}: #{base}#{project.url}")
      shell.info("  Reviews:        #{base}#{project.url}/reviews")
    end)

    if summary.tokens != %{} do
      shell.info("")
      shell.info("Proposals (public read-only links):")

      summary.tokens
      |> Enum.sort_by(fn {label, _token} -> label end)
      |> Enum.each(fn {label, token} ->
        shell.info("  #{String.pad_trailing(label, 16)} #{base}/proposals/#{token}")
      end)
    end

    shell.info("")
    shell.info("Sign in at #{base}/sign-in")
  end
end
