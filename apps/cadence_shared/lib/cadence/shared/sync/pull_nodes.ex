defmodule Cadence.Shared.Sync.PullNodes do
  @moduledoc """
  Cloud → local pull request (spec §10.3, §10.6).

  `project_id` scopes the pull; `since` is an opaque cursor, where `nil`
  requests from the beginning.
  """

  @enforce_keys [:project_id]
  @derive {Jason.Encoder, only: [:project_id, :since]}
  defstruct project_id: nil, since: nil

  @type t :: %__MODULE__{project_id: String.t(), since: String.t() | nil}
end
