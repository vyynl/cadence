defmodule Cadence.Shared.Sync.UnionResponse do
  @moduledoc """
  Response to `Union` (spec §10.6): a pending proposal reference.

  Union creates a proposal, not a node. The meld node exists only after an
  approver decides, so the response carries the stable review identifiers and
  the public review URL built by the server (`CAD_PUBLIC_URL`). The URL is
  nullable: a daemon talking to an older server falls back to deriving it from
  `CAD_SERVER_URL`.
  """

  @enforce_keys [:proposal_id, :proposal_token]
  @derive {Jason.Encoder, only: [:proposal_id, :proposal_token, :proposal_url, :status, :kind]}
  defstruct proposal_id: nil, proposal_token: nil, proposal_url: nil, status: nil, kind: nil

  @type t :: %__MODULE__{
          proposal_id: String.t(),
          proposal_token: String.t(),
          proposal_url: String.t() | nil,
          status: String.t() | nil,
          kind: String.t() | nil
        }
end
