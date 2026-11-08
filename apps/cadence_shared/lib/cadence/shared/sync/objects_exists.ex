defmodule Cadence.Shared.Sync.ObjectsExists do
  @moduledoc """
  Sync existence handshake request (spec §10.2, §10.6).

  The daemon asks which object SHAs the server already holds before a push, so
  present objects can be omitted from every node's `git_objects`. The response
  is `%{present: [sha]}`; the server answers from loose files and pack indexes.
  """

  @enforce_keys [:project_id, :shas]
  @derive {Jason.Encoder, only: [:project_id, :shas]}
  defstruct project_id: nil, shas: []

  @type t :: %__MODULE__{project_id: String.t(), shas: [String.t()]}
end
