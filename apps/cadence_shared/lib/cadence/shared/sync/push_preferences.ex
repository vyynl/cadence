defmodule Cadence.Shared.Sync.PushPreferences do
  @moduledoc """
  Per-user, per-project preference sync (spec §10.5, §10.6).

  Carries the membership's `active_heads` and `session_pointer` so machines
  agree on where a user left off.
  """

  @enforce_keys [:project_id]
  @derive {Jason.Encoder, only: [:project_id, :active_heads, :session_pointer]}
  defstruct project_id: nil, active_heads: [], session_pointer: nil

  @type t :: %__MODULE__{
          project_id: String.t(),
          active_heads: [String.t()],
          session_pointer: String.t() | nil
        }
end
