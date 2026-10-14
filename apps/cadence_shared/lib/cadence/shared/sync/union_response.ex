defmodule Cadence.Shared.Sync.UnionResponse do
  @moduledoc """
  Response to `Union` (spec §10.6): the ID of the created meld node.
  """

  @enforce_keys [:meld_node_id]
  @derive {Jason.Encoder, only: [:meld_node_id]}
  defstruct meld_node_id: nil

  @type t :: %__MODULE__{meld_node_id: String.t()}
end
