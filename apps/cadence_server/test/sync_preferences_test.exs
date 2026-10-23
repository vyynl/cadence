defmodule Cadence.ServerWeb.SyncPreferencesTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Cadence.Server.{Accounts, Repo}
  alias Cadence.Server.Accounts.User
  alias Cadence.Shared.{Membership, Project}

  setup do
    user = seed_user("prefs")
    project = insert_project(user)
    insert_membership(user, project, :owner)
    {:ok, api_key} = Accounts.create_api_key(user, "prefs-test")

    %{
      user: user,
      project: project,
      plaintext: api_key.__metadata__.plaintext_api_key
    }
  end

  test "accepts newer preferences and returns them on pull", %{
    user: user,
    project: project,
    plaintext: plaintext
  } do
    Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:#{project.id}")

    active_heads = [Ecto.UUID.generate(), Ecto.UUID.generate()]
    pointer = Ecto.UUID.generate()
    updated_at = now_iso()

    response =
      authed_conn(plaintext)
      |> post_json(
        "/sync/preferences",
        preferences_payload(project.id, active_heads, pointer, updated_at)
      )

    assert %{"preferences" => preferences} = json_response(response, 200)
    assert preferences["active_heads"] == active_heads
    assert preferences["session_pointer"] == pointer
    assert preferences["updated_at"] == updated_at

    stored = Repo.get_by!(Membership, user_id: user.id, project_id: project.id)
    assert stored.active_heads == active_heads
    assert stored.session_pointer == pointer
    assert stored.preferences_updated_at
    assert stored.last_seen_at

    assert_receive {:preferences_updated, project_id, user_id}
    assert project_id == project.id
    assert user_id == user.id

    pull =
      authed_conn(plaintext)
      |> get("/sync/nodes?project_id=#{project.id}")

    assert %{"preferences" => pulled} = json_response(pull, 200)
    assert pulled == preferences
  end

  test "stale preferences do not clobber newer state", %{
    user: user,
    project: project,
    plaintext: plaintext
  } do
    newer = now_iso()
    {:ok, newer_dt, _offset} = DateTime.from_iso8601(newer)
    older = DateTime.add(newer_dt, -1, :second) |> DateTime.to_iso8601()
    newer_head = Ecto.UUID.generate()
    older_head = Ecto.UUID.generate()

    assert %{"preferences" => first} =
             authed_conn(plaintext)
             |> post_json(
               "/sync/preferences",
               preferences_payload(project.id, [newer_head], Ecto.UUID.generate(), newer)
             )
             |> json_response(200)

    assert first["active_heads"] == [newer_head]

    Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:#{project.id}")

    assert %{"preferences" => second} =
             authed_conn(plaintext)
             |> post_json(
               "/sync/preferences",
               preferences_payload(project.id, [older_head], Ecto.UUID.generate(), older)
             )
             |> json_response(200)

    assert second == first

    assert Repo.get_by!(Membership, user_id: user.id, project_id: project.id).active_heads == [
             newer_head
           ]

    refute_receive {:preferences_updated, _, _}, 100
  end

  test "viewers and outsiders cannot push preferences", %{
    project: project
  } do
    viewer = seed_user("prefs-viewer")
    insert_membership(viewer, project, :viewer)
    {:ok, viewer_key} = Accounts.create_api_key(viewer, "prefs-viewer")

    outsider = seed_user("prefs-outsider")
    {:ok, outsider_key} = Accounts.create_api_key(outsider, "prefs-outsider")

    for key <- [viewer_key, outsider_key] do
      assert %{"error" => _} =
               authed_conn(key.__metadata__.plaintext_api_key)
               |> post_json(
                 "/sync/preferences",
                 preferences_payload(project.id, [], nil, now_iso())
               )
               |> json_response(403)
    end
  end

  test "rejects malformed preference payloads", %{
    project: project,
    plaintext: plaintext
  } do
    assert %{"error" => "invalid sync payload"} =
             authed_conn(plaintext)
             |> post_json("/sync/preferences", %{})
             |> json_response(422)

    assert %{"error" => "invalid active_heads"} =
             authed_conn(plaintext)
             |> post_json(
               "/sync/preferences",
               preferences_payload(project.id, ["nope"], nil, now_iso())
             )
             |> json_response(422)

    assert %{"error" => "invalid updated_at"} =
             authed_conn(plaintext)
             |> post_json(
               "/sync/preferences",
               preferences_payload(project.id, [], nil, "not-a-timestamp")
             )
             |> json_response(422)

    assert %{"error" => "invalid updated_at"} =
             authed_conn(plaintext)
             |> post_json(
               "/sync/preferences",
               %{"project_id" => project.id, "active_heads" => []}
             )
             |> json_response(422)
  end

  test "requires authentication", %{project: project} do
    conn =
      post_json(
        build_conn(),
        "/sync/preferences",
        preferences_payload(project.id, [], nil, now_iso())
      )

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "pull returns empty preferences before the first push", %{
    project: project,
    plaintext: plaintext
  } do
    assert %{"preferences" => preferences} =
             authed_conn(plaintext)
             |> get("/sync/nodes?project_id=#{project.id}")
             |> json_response(200)

    assert preferences == %{
             "active_heads" => [],
             "session_pointer" => nil,
             "updated_at" => nil
           }
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp preferences_payload(project_id, active_heads, session_pointer, updated_at) do
    %{
      "project_id" => project_id,
      "active_heads" => active_heads,
      "session_pointer" => session_pointer,
      "updated_at" => updated_at
    }
  end

  defp seed_user(label) do
    Ash.Seed.seed!(User, %{
      email: "prefs-#{label}-#{System.unique_integer([:positive])}@example.com",
      name: label
    })
  end

  defp insert_project(user) do
    %Project{}
    |> Project.changeset(%{
      name: "Prefs",
      slug: "prefs-#{System.unique_integer([:positive])}",
      owner_id: user.id
    })
    |> Repo.insert!()
  end

  defp insert_membership(user, project, role) do
    %Membership{}
    |> Membership.changeset(%{
      user_id: user.id,
      project_id: project.id,
      role: role
    })
    |> Repo.insert!()
  end

  defp authed_conn(plaintext) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{plaintext}")
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end
end
