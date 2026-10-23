defmodule Cadence.Shared.Sync.PullNodesResponse do
  @moduledoc """
  Response to `PullNodes` (spec §10.6).

  `nodes` is the batch of nodes since the cursor; `cursor` is the new cursor
  to pass on the next pull.
  """

  @enforce_keys [:nodes, :cursor]
  @derive {Jason.Encoder, only: [:nodes, :cursor, :preferences]}
  defstruct nodes: [], cursor: nil, preferences: nil

  @type t :: %__MODULE__{
          nodes: [map()],
          cursor: String.t() | nil,
          preferences: map() | nil
        }
end
