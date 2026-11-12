defmodule Cadence.Server.Accounts.Validations.ByteSize do
  @moduledoc """
  Validates that a binary attribute (when present) has a byte length in a range.

  `Ash.Type.Binary` has no length constraints, so credential ids, AAGUIDs, and
  other raw-byte columns are bounded here instead.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl Ash.Resource.Validation
  def validate(changeset, opts, _context) do
    attribute = opts[:attribute]
    min = opts[:min] || 0
    max = opts[:max]

    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil ->
        :ok

      value when is_binary(value) ->
        size = byte_size(value)

        if size >= min and (is_nil(max) or size <= max) do
          :ok
        else
          {:error, invalid(changeset, attribute, value, range_message(min, max))}
        end

      value ->
        {:error, invalid(changeset, attribute, value, "must be a binary")}
    end
  end

  @impl Ash.Resource.Validation
  def describe(opts) do
    [message: range_message(opts[:min] || 0, opts[:max]), vars: []]
  end

  defp range_message(min, nil), do: "must be at least #{min} bytes"
  defp range_message(min, max), do: "must be between #{min} and #{max} bytes"

  defp invalid(changeset, attribute, value, message) do
    InvalidAttribute.exception(
      field: attribute,
      value: Ash.Resource.Validation.maybe_redact(changeset, attribute, value),
      message: message
    )
  end
end

defmodule Cadence.Server.Accounts.Validations.Label do
  @moduledoc """
  Rejects credential labels containing control or bidirectional formatting
  characters (plan §7.2 / §7.7). Length is enforced by the `:string`
  constraints on the attribute.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  # Cc = control, Cf = format (includes bidi overrides/isolates),
  # Zl/Zp = line/paragraph separators. None belong in a short UI label.
  @forbidden ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u

  @impl Ash.Resource.Validation
  def validate(changeset, opts, _context) do
    attribute = opts[:attribute]

    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil ->
        :ok

      value when is_binary(value) ->
        if Regex.match?(@forbidden, value) do
          {:error,
           InvalidAttribute.exception(
             field: attribute,
             value: Ash.Resource.Validation.maybe_redact(changeset, attribute, value),
             message: "must not contain control or bidirectional characters"
           )}
        else
          :ok
        end

      value ->
        {:error,
         InvalidAttribute.exception(
           field: attribute,
           value: Ash.Resource.Validation.maybe_redact(changeset, attribute, value),
           message: "must be a string"
         )}
    end
  end

  @impl Ash.Resource.Validation
  def describe(_opts) do
    [message: "must not contain control or bidirectional characters", vars: []]
  end
end

defmodule Cadence.Server.Accounts.Validations.Transports do
  @moduledoc """
  Restricts authenticator transports to the WebAuthn allowlist (plan §7.2).

  Transports are client-supplied metadata and never used for authorization.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @allowed ~w(usb nfc ble hybrid internal smart-card)

  @impl Ash.Resource.Validation
  def validate(changeset, opts, _context) do
    attribute = opts[:attribute]

    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil ->
        :ok

      transports when is_list(transports) ->
        if Enum.all?(transports, &(&1 in @allowed)) do
          :ok
        else
          {:error,
           InvalidAttribute.exception(
             field: attribute,
             value: transports,
             message: "must be a subset of #{Enum.join(@allowed, ", ")}"
           )}
        end

      _value ->
        {:error,
         InvalidAttribute.exception(
           field: attribute,
           value: nil,
           message: "must be a list of transports"
         )}
    end
  end

  @impl Ash.Resource.Validation
  def describe(_opts) do
    [message: "must be a subset of #{Enum.join(@allowed, ", ")}", vars: []]
  end

  @doc "The accepted transport values, exposed for tests and callers."
  def allowed, do: @allowed
end
