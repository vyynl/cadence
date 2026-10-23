defmodule Cadence.Server.Projects do
  @moduledoc """
  Server-side project provisioning for daemons.

  A daemon registers its local project by ID (IDs are identity-mapped). The
  first caller becomes the owner; repeat calls from an existing `owner` or
  `trusted` member are idempotent. Project metadata is not overwritten after
  creation (the daemon owns its local project record).
  """

  alias Cadence.Server.Repo
  alias Cadence.Shared.{Membership, Project, UUID}

  @type user :: Ash.Resource.record()

  @doc """
  Provisions a project from a daemon payload.

  Accepts `%{"project" => %{"id", "name", "slug"}}`. Returns
  `{:ok, project, :created | :existing}` or `{:error, reason}`.
  """
  @spec provision(user(), map()) ::
          {:ok, Project.t(), :created | :existing} | {:error, term()}
  def provision(user, %{"project" => project}) when is_map(project) do
    with {:ok, project_id} <- UUID.cast(project["id"]),
         {:ok, name} <- required_string(project["name"]),
         {:ok, slug} <- required_string(project["slug"]) do
      case Repo.get(Project, project_id) do
        nil -> create_project(user, project_id, name, slug)
        existing -> existing_project(user, existing)
      end
    else
      :error -> {:error, :invalid_payload}
    end
  end

  def provision(_user, _params), do: {:error, :invalid_payload}

  defp create_project(user, project_id, name, slug) do
    if Repo.get_by(Project, slug: slug) do
      {:error, :project_conflict}
    else
      result =
        Repo.transaction(fn ->
          project = insert_project!(project_id, name, slug, user.id)
          insert_membership!(user.id, project.id, :owner)
          project
        end)

      case result do
        {:ok, project} -> {:ok, project, :created}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, classify_changeset(changeset)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp existing_project(user, project) do
    case Repo.get_by(Membership, user_id: user.id, project_id: project.id) do
      %{role: role} when role in [:owner, :trusted] ->
        {:ok, project, :existing}

      %{role: :viewer} ->
        {:error, :forbidden}

      nil ->
        if project.owner_id == user.id do
          case insert_membership(user.id, project.id, :owner) do
            {:ok, _membership} -> {:ok, project, :existing}
            {:error, _changeset} -> {:error, :invalid_project}
          end
        else
          {:error, :project_conflict}
        end
    end
  end

  defp classify_changeset(%Ecto.Changeset{errors: errors}) do
    if Enum.any?(errors, fn
         {:slug, {"has already been taken", _opts}} -> true
         _ -> false
       end) do
      :project_conflict
    else
      :invalid_project
    end
  end

  defp insert_project!(project_id, name, slug, owner_id) do
    case %Project{}
         |> Project.changeset(%{
           id: project_id,
           name: name,
           slug: slug,
           owner_id: owner_id
         })
         |> Repo.insert() do
      {:ok, project} -> project
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_membership!(user_id, project_id, role) do
    case insert_membership(user_id, project_id, role) do
      {:ok, membership} -> membership
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_membership(user_id, project_id, role) do
    %Membership{}
    |> Membership.changeset(%{
      user_id: user_id,
      project_id: project_id,
      role: role
    })
    |> Repo.insert()
  end

  defp required_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :error
      value -> {:ok, value}
    end
  end

  defp required_string(_value), do: :error
end
