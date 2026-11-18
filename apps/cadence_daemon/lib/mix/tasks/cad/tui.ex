defmodule Mix.Tasks.Cad.Tui do
  use Mix.Task

  @shortdoc "Open the daemon terminal UI: mix cad.tui [options]"

  @moduledoc """
  Opens the daemon TUI against the running daemon's Unix socket.

      mix cad.tui
      mix cad.tui --project my-project
      mix cad.tui --socket /run/cadence/daemon.sock --refresh 2000

  The TUI is a pure socket client, so it never starts the daemon, touches the
  database, or reads the Git store. Project resolution order is `--project`
  (slug or id), then an exact `work_dir` match on the current directory, then
  an in-app picker.

  Keys: `h/j/k/l` or arrows move, `Enter` switches, `s` spawns, `u` unions,
  `p` lists proposals, `d`/`D` show the node/docs diff, `g` queues docs sync,
  `r` refreshes, `?` opens help, `q` quits. See `Cadence.Daemon.TUI`.
  """

  @switches [project: :string, socket: :string, refresh: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: @switches)

    if argv != [] do
      Mix.raise("usage: mix cad.tui [--project SLUG_OR_ID] [--socket PATH] [--refresh MS]")
    end

    # Never `Mix.Task.run("app.start")`: the TUI is a socket client and must
    # not boot the daemon's supervision tree (Iron Law 13).
    Mix.Task.run("app.config")

    Cadence.Daemon.TUI.main(tui_opts(opts))
  end

  defp tui_opts(opts) do
    []
    |> put_unless_nil(:project, opts[:project])
    |> put_unless_nil(:socket_path, opts[:socket])
    |> put_unless_nil(:refresh_ms, opts[:refresh])
  end

  defp put_unless_nil(opts, _key, nil), do: opts
  defp put_unless_nil(opts, key, value), do: Keyword.put(opts, key, value)
end
