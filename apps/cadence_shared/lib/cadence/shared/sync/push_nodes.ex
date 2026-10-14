defmodule Cadence.Shared.Sync.PushNodes do
  @moduledoc """
  Local → cloud push message (spec §10.2, §10.6).

  `nodes` is a list of maps, each `%{local_id, git_objects, metadata}`, where
  `git_objects` are the referenced Git objects and `metadata` is the node's
  Ecto row attributes.
  """

  @enforce_keys [:nodes]
  @derive {Jason.Encoder, only: [:nodes]}
  defstruct nodes: []

  @type t :: %__MODULE__{nodes: [map()]}
end
