defmodule Cadence.Shared.Sync.Union do
  @moduledoc """
  Server-first meld/union request (spec §6.5, §10.6).

  Requests a new meld node whose parents are `parent_node_ids`.
  """

  @enforce_keys [:project_id, :parent_node_ids]
  @derive {Jason.Encoder, only: [:project_id, :parent_node_ids]}
  defstruct project_id: nil, parent_node_ids: []

  @type t :: %__MODULE__{project_id: String.t(), parent_node_ids: [String.t()]}
end
