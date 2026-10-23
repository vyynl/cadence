defmodule Cadence.ServerWeb.SyncProjectsTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Cadence.Server.{Accounts, Repo}
  alias Cadence.Server.Accounts.User
  alias Cadence.Shared.{Membership, Project}

  setup do
    user = seed_user("provisioner")
    {:ok, api_key} = Accounts.create_api_key(user, "provision-test")
    %{user: user, plaintext: api_key.__metadata__.plaintext_api_key}
  end

  test "creates the project and owner membership, then is idempotent",
       %{user: user, plaintext: plaintext} do
    project_id = Ecto.UUID.generate()
    slug = unique_slug()
    payload = project_payload(project_id, slug)

    created = authed_conn(plaintext) |> post_json("/sync/projects", payload)

    assert %{"project" => project} = json_response(created, 201)
    assert project["id"] == project_id
    assert project["name"] == "Provisioned"
    assert project["slug"] == slug
    assert project["owner_id"] == user.id
    assert Repo.get!(Project, project_id).name == "Provisioned"

    assert %Membership{role: :owner} =
             Repo.get_by!(Membership, user_id: user.id, project_id: project_id)

    repeat = authed_conn(plaintext) |> post_json("/sync/projects", payload)

    assert %{"project" => repeated} = json_response(repeat, 200)
    assert repeated["id"] == project_id
    assert Repo.aggregate(Project, :count, :id) == 1
  end

  test "a different user cannot claim an existing project",
       %{user: owner, plaintext: plaintext} do
    project_id = Ecto.UUID.generate()
    payload = project_payload(project_id, unique_slug())

    assert %{"project" => _} =
             authed_conn(plaintext) |> post_json("/sync/projects", payload) |> json_response(201)

    other = seed_user("other")
    {:ok, other_key} = Accounts.create_api_key(other, "other-provision")
    other_plaintext = other_key.__metadata__.plaintext_api_key

    assert %{"error" => "project already exists or is owned by another user"} =
             authed_conn(other_plaintext)
             |> post_json("/sync/projects", payload)
             |> json_response(409)

    assert Repo.get_by(Membership, user_id: other.id, project_id: project_id) == nil
    refute other.id == owner.id
  end

  test "viewers cannot provision" do
    viewer = seed_user("viewer")
    project_id = Ecto.UUID.generate()
    insert_project(project_id, unique_slug())

    %Membership{}
    |> Membership.changeset(%{user_id: viewer.id, project_id: project_id, role: :viewer})
    |> Repo.insert!()

    {:ok, viewer_key} = Accounts.create_api_key(viewer, "viewer-provision")

    assert %{"error" => "not a project member"} =
             authed_conn(viewer_key.__metadata__.plaintext_api_key)
             |> post_json("/sync/projects", project_payload(project_id, "ignored-slug"))
             |> json_response(403)

    assert %Membership{role: :viewer} =
             Repo.get_by!(Membership, user_id: viewer.id, project_id: project_id)
  end

  test "rejects a slug owned by another project", %{plaintext: plaintext} do
    slug = unique_slug()
    insert_project(Ecto.UUID.generate(), slug)

    assert %{"error" => _} =
             authed_conn(plaintext)
             |> post_json("/sync/projects", project_payload(Ecto.UUID.generate(), slug))
             |> json_response(409)
  end

  test "rejects malformed payloads", %{plaintext: plaintext} do
    assert %{"error" => "invalid sync payload"} =
             authed_conn(plaintext)
             |> post_json("/sync/projects", %{"project" => %{"id" => "nope"}})
             |> json_response(422)

    assert %{"error" => "invalid sync payload"} =
             authed_conn(plaintext)
             |> post_json("/sync/projects", %{})
             |> json_response(422)
  end

  test "requires authentication" do
    conn =
      post_json(
        build_conn(),
        "/sync/projects",
        project_payload(Ecto.UUID.generate(), unique_slug())
      )

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
    assert Repo.aggregate(Project, :count, :id) == 0
  end

  defp seed_user(label) do
    Ash.Seed.seed!(User, %{
      email: "provision-#{label}-#{System.unique_integer([:positive])}@example.com",
      name: label
    })
  end

  defp insert_project(id, slug) do
    %Project{}
    |> Project.changeset(%{
      id: id,
      name: "Existing",
      slug: slug,
      owner_id: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end

  defp project_payload(id, slug) do
    %{"project" => %{"id" => id, "name" => "Provisioned", "slug" => slug}}
  end

  defp unique_slug do
    "provision-#{System.unique_integer([:positive])}"
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
