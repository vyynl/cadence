defmodule Cadence.ServerWeb.RunLogController do
  @moduledoc """
  Downloads a run's captured log (spec §7.2, §8.3).

  Member-only, like the run pages: `Actions.Runs.get/3` re-checks membership,
  and the log is read through `Actions.Runs.log/1` from the recorded `log_path`
  (never a client-supplied path). Every refusal is a plain 404, so a non-member
  cannot distinguish an unknown run from a forbidden one.

  Responses are always `text/plain` with `content-disposition: attachment`, so
  captured output can never render inline as HTML by the application origin.
  """

  use Cadence.ServerWeb, :controller

  alias Cadence.Server.{Actions.Runs, Portfolio}

  def show(conn, %{"slug" => slug, "run_id" => run_id}) do
    with {:ok, project} <- Portfolio.get_project_by_slug(slug),
         %{id: user_id} <- conn.assigns[:current_user],
         {:ok, run} <- Runs.get(%{id: user_id}, project.id, run_id),
         {:ok, log} <- Runs.log(run) do
      conn
      |> put_resp_content_type("text/plain", "utf-8")
      |> put_resp_header("content-disposition", ~s(attachment; filename="run-#{run.id}.log"))
      |> put_resp_header("cache-control", "private, no-store")
      |> send_resp(200, log)
    else
      _other -> send_resp(conn, 404, "Not found")
    end
  end

  def show(conn, _params), do: send_resp(conn, 404, "Not found")
end
