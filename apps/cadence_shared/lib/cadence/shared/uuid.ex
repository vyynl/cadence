defmodule Cadence.Shared.UUID do
  @moduledoc """
  UUID casting shared by the daemon and server.

  Centralizes the "is this a valid UUID string?" check so API boundaries can
  reject bad identifiers instead of letting an `Ecto.Query.CastError` escape.
  """

  @doc "Casts a UUID string, returning `{:ok, uuid}` or `:error`."
  @spec cast(term()) :: {:ok, Ecto.UUID.t()} | :error
  def cast(value) when is_binary(value), do: Ecto.UUID.cast(value)
  def cast(_value), do: :error

  @doc "Returns whether `value` is a valid UUID string."
  @spec valid?(term()) :: boolean()
  def valid?(value), do: match?({:ok, _}, cast(value))
end
