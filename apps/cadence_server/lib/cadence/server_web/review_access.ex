defmodule Cadence.ServerWeb.ReviewAccess do
  @moduledoc """
  The single access rule for member-only project surfaces (spec §6.6, §7.2).

  Used by the review hub/detail pages and the action-run list/detail pages. The
  visitor must be a project member with `Authorization.can_view?/1`. Public
  pages (the portfolio, project home, `/proposals/:token`) never use this
  module.

  Callers run this in `handle_params/3` — a refused visitor must be redirected,
  and an `assign_async` failure cannot navigate.
  """

  alias Cadence.Server.{Authorization, Portfolio}

  @type refusal :: {:error, :not_found | :forbidden}

  @doc """
  Resolves the project and the visitor's membership.

  `:not_found` means the slug does not resolve; `:forbidden` covers anonymous
  visitors, non-members, and members whose role cannot view (spec §7.2).
  """
  @spec authorize(map() | nil, String.t() | nil) ::
          {:ok, Cadence.Shared.Project.t(), Cadence.Shared.Membership.t()} | refusal()
  def authorize(current_user, slug) do
    with %{id: user_id} <- current_user,
         {:ok, project} <- Portfolio.get_project_by_slug(slug),
         %{} = membership <- Authorization.membership(user_id, project.id),
         true <- Authorization.can_view?(membership) do
      {:ok, project, membership}
    else
      {:error, :not_found} -> {:error, :not_found}
      _other -> {:error, :forbidden}
    end
  end
end
