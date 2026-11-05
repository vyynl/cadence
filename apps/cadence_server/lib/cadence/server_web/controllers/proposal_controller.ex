defmodule Cadence.ServerWeb.ProposalController do
  @moduledoc """
  Public, read-only proposal page (spec §6.6).

  There is no mutation surface here: approving or rejecting is the review UI's
  job (4c) and re-checks membership independently. This controller never reads
  the session, membership, or raw-view flags, and it never renders identities.
  """

  use Cadence.ServerWeb, :controller

  alias Cadence.Server.{Portfolio, ProposalView, Proposals, PublicContent}
  alias Cadence.ServerWeb.Metadata
  alias Cadence.Shared.Node

  def show(conn, %{"token" => token}) do
    with {:ok, proposal} <- Proposals.get_by_token(token),
         {:ok, project} <- Portfolio.get_project(proposal.project_id) do
      # Incidents isolate *result* content. A promotion renders no result, and
      # its target is a separate public node, so it is not isolated here.
      result =
        if proposal.kind == :meld and ProposalView.isolated?(proposal) do
          :isolated
        else
          ProposalView.result(project, proposal)
        end

      render(conn, :show,
        page_title: "Proposal",
        page_description:
          "A reviewable #{proposal.kind} proposal for #{project.name} on Cadence.",
        canonical_url: Metadata.canonical("/proposals/#{proposal.token}"),
        project: %{name: project.name, slug: project.slug},
        proposal: public_proposal(proposal),
        parents: Enum.map(ProposalView.parents(proposal), &public_node/1),
        target_node: public_node(ProposalView.target_node(proposal)),
        result: result
      )
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> render(:not_found,
          page_title: "Proposal not found",
          page_description: "Proposal not found on Cadence."
        )
    end
  end

  # Identity fields (`proposer_id`, `reviewer_id`) and internal row IDs never
  # reach the template.
  defp public_proposal(proposal) do
    Map.take(proposal, [:token, :kind, :status, :created_at, :decided_at])
  end

  defp public_node(nil), do: nil

  defp public_node(%Node{} = node) do
    %{
      id: node.id,
      message: PublicContent.redact_message(node.message),
      flags: node.flags,
      pinned: node.pinned,
      git_commit_sha: node.git_commit_sha,
      created_at: node.created_at
    }
  end
end
