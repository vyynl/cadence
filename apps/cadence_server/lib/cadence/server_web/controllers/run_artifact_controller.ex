defmodule Cadence.ServerWeb.RunArtifactController do
  @moduledoc """
  Downloads one collected action-run artifact (spec §7.2, §8.3).

  Every refusal is a plain 404: anonymous visitors, non-members, a run from
  another project, an unknown artifact, and any path outside the recorded
  collection look identical. The run is resolved through `Actions.Runs.get/3`
  (which re-checks membership) and the relative path through
  `Actions.Runs.read_artifact/2` (which accepts only an exact entry from
  `Artifacts.list/1` and requires a regular file).

  Responses are always `application/octet-stream` with
  `content-disposition: attachment`, so project-owned output can never be
  rendered inline as HTML by the application origin.
  """

  use Cadence.ServerWeb, :controller

  alias Cadence.Server.{Actions.Runs, Portfolio}

  def show(conn, %{"slug" => slug, "run_id" => run_id, "path" => path}) do
    relative = relative_path(path)

    with {:ok, project} <- Portfolio.get_project_by_slug(slug),
         %{id: user_id} <- conn.assigns[:current_user],
         {:ok, run} <- Runs.get(%{id: user_id}, project.id, run_id),
         {:ok, absolute} <- Runs.read_artifact(run, relative) do
      conn
      |> put_resp_content_type("application/octet-stream", nil)
      |> put_resp_header("content-disposition", "attachment")
      |> put_resp_header("cache-control", "private, no-store")
      |> send_file(200, absolute)
    else
      _other -> send_resp(conn, 404, "Not found")
    end
  rescue
    # The file can vanish between the allowlist check and the send; that is a
    # 404, never a 500.
    File.Error -> send_resp(conn, 404, "Not found")
  end

  def show(conn, _params), do: send_resp(conn, 404, "Not found")

  # A controller wildcard arrives as a list of decoded segments. Joining is
  # only for the allowlist comparison: `read_artifact/2` still accepts nothing
  # that `Artifacts.list/1` did not record, so `..` segments cannot escape.
  defp relative_path(segments) when is_list(segments), do: Enum.join(segments, "/")
  defp relative_path(path) when is_binary(path), do: path
  defp relative_path(_path), do: ""
end
