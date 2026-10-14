defmodule Cadence.Shared.Sync.PullNodes do
  @moduledoc """
  Cloud → local pull request (spec §10.3, §10.6).

  `since` is an opaque cursor; `nil` requests from the beginning.
  """

  @enforce_keys [:since]
  @derive {Jason.Encoder, only: [:since]}
  defstruct since: nil

  @type t :: %__MODULE__{since: String.t() | nil}
end
