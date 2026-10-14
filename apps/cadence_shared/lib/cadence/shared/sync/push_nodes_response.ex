defmodule Cadence.Shared.Sync.PushNodesResponse do
  @moduledoc """
  Response to `PushNodes` (spec §10.6).

  `mappings` is a list of `%{local_id, cloud_id}` pairs used to update the
  daemon's sync ledger.
  """

  @enforce_keys [:mappings]
  @derive {Jason.Encoder, only: [:mappings]}
  defstruct mappings: []

  @type t :: %__MODULE__{mappings: [%{local_id: String.t(), cloud_id: String.t()}]}
end
