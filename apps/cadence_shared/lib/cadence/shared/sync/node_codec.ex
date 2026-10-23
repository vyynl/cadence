defmodule Cadence.Shared.Sync.NodeCodec do
  @moduledoc """
  Canonical wire encoding for sync node metadata and Git objects (spec §10.6).

  The daemon uses `encode_node/2` for pushes and `decode_node/1` for pulls; the
  server uses the same codec for its pull responses and object decoding. Keeping
  this in `cadence_shared` prevents the daemon and server from drifting on flags,
  docs states, timestamps, or base64 object framing.
  """

  alias Cadence.Shared.{GitStore, Node}

  @doc """
  Encodes a node and its Git objects into the sync wire shape.

  `objects` are `%{sha, type, data}` maps as returned by
  `Cadence.Shared.GitStore.objects_from/2`.
  """
  @spec encode_node(Node.t(), [GitStore.object()]) :: map()
  def encode_node(node, objects) do
    %{
      "id" => node.id,
      "project_id" => node.project_id,
      "git_commit_sha" => node.git_commit_sha,
      "parents" => node.parents,
      "flags" => encode_flags(node.flags),
      "pinned" => node.pinned,
      "message" => node.message,
      "session_metadata" => node.session_metadata,
      "created_by" => node.created_by,
      "created_at" => encode_datetime(node.created_at),
      "docs_state" => encode_docs_state(node.docs_state),
      "git_objects" => encode_objects(objects)
    }
  end

  @doc """
  Decodes a sync wire node into changeset attributes plus decoded Git objects.

  Returns `{:ok, %{attrs: attrs, objects: objects}}` or
  `{:error, reason}` for malformed flags/docs states/timestamps/objects.
  """
  @spec decode_node(map()) ::
          {:ok, %{attrs: map(), objects: [map()]}} | {:error, atom()}
  def decode_node(node) when is_map(node) do
    with {:ok, id} <- required_string(node, "id"),
         {:ok, project_id} <- required_string(node, "project_id"),
         {:ok, git_commit_sha} <- required_string(node, "git_commit_sha"),
         {:ok, created_by} <- required_string(node, "created_by"),
         {:ok, parents} <- parents(Map.get(node, "parents", [])),
         {:ok, flags} <- decode_flags(Map.get(node, "flags", [])),
         {:ok, docs_state} <- decode_docs_state(Map.get(node, "docs_state")),
         {:ok, created_at} <- decode_datetime(Map.get(node, "created_at")),
         {:ok, session_metadata} <- session_metadata(Map.get(node, "session_metadata")),
         {:ok, objects} <- decode_objects(Map.get(node, "git_objects", [])) do
      {:ok,
       %{
         attrs: %{
           id: id,
           project_id: project_id,
           git_commit_sha: git_commit_sha,
           parents: parents,
           flags: flags,
           pinned: Map.get(node, "pinned") == true,
           message: Map.get(node, "message"),
           session_metadata: session_metadata,
           created_by: created_by,
           created_at: created_at,
           docs_state: docs_state
         },
         objects: objects
       }}
    end
  end

  def decode_node(_node), do: {:error, :invalid_node}

  @doc "Encodes flags as their wire strings."
  @spec encode_flags([atom()]) :: [String.t()]
  def encode_flags(flags), do: Enum.map(flags || [], &encode_flag/1)

  defp encode_flag(flag) when is_atom(flag), do: Atom.to_string(flag)
  defp encode_flag(flag) when is_binary(flag), do: flag

  @doc "Decodes wire flag strings into the allowed atoms."
  @spec decode_flags([String.t()]) :: {:ok, [atom()]} | {:error, :invalid_flag}
  def decode_flags(flags) when is_list(flags) do
    flags
    |> Enum.reduce_while({:ok, []}, fn flag, {:ok, acc} ->
      case decode_flag(flag) do
        {:ok, flag} -> {:cont, {:ok, [flag | acc]}}
        :error -> {:halt, {:error, :invalid_flag}}
      end
    end)
    |> case do
      {:ok, flags} -> {:ok, Enum.reverse(flags)}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_flags(_flags), do: {:error, :invalid_flag}

  defp decode_flag(flag) when is_atom(flag) do
    if flag in Node.flags(), do: {:ok, flag}, else: :error
  end

  defp decode_flag(flag) when is_binary(flag) do
    Enum.find_value(Node.flags(), :error, fn allowed ->
      if Atom.to_string(allowed) == flag, do: {:ok, allowed}
    end)
  end

  defp decode_flag(_flag), do: :error

  @doc "Encodes a docs state as its wire string."
  @spec encode_docs_state(atom() | nil) :: String.t() | nil
  def encode_docs_state(nil), do: nil
  def encode_docs_state(state) when is_atom(state), do: Atom.to_string(state)
  def encode_docs_state(state) when is_binary(state), do: state

  @doc "Decodes a wire docs state string into its atom."
  @spec decode_docs_state(String.t() | nil) ::
          {:ok, atom()} | {:error, :invalid_docs_state}
  def decode_docs_state(nil), do: {:error, :invalid_docs_state}

  def decode_docs_state(state) when is_atom(state) do
    if state in Node.docs_states(), do: {:ok, state}, else: {:error, :invalid_docs_state}
  end

  def decode_docs_state(state) when is_binary(state) do
    Enum.find_value(Node.docs_states(), {:error, :invalid_docs_state}, fn allowed ->
      if Atom.to_string(allowed) == state, do: {:ok, allowed}
    end)
  end

  def decode_docs_state(_state), do: {:error, :invalid_docs_state}

  @doc "Encodes a timestamp as ISO8601, or `nil`."
  @spec encode_datetime(DateTime.t() | nil) :: String.t() | nil
  def encode_datetime(nil), do: nil
  def encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  @doc "Decodes an ISO8601 timestamp into UTC."
  @spec decode_datetime(String.t() | nil) ::
          {:ok, DateTime.t() | nil} | {:error, :invalid_created_at}
  def decode_datetime(nil), do: {:ok, nil}

  def decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.shift_zone!(datetime, "Etc/UTC")}
      _ -> {:error, :invalid_created_at}
    end
  end

  def decode_datetime(_value), do: {:error, :invalid_created_at}

  @doc "Encodes Git objects for transfer (base64 payloads)."
  @spec encode_objects([map()]) :: [map()]
  def encode_objects(objects), do: Enum.map(objects, &encode_object/1)

  defp encode_object(%{sha: sha, type: type, data: data}) do
    %{"sha" => sha, "type" => Atom.to_string(type), "data" => Base.encode64(data)}
  end

  @doc "Decodes and validates base64 Git objects."
  @spec decode_objects([map()]) :: {:ok, [map()]} | {:error, :invalid_objects}
  def decode_objects(objects) when is_list(objects) do
    objects
    |> Enum.reduce_while({:ok, []}, fn object, {:ok, acc} ->
      case decode_object(object) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_objects}}
      end
    end)
    |> case do
      {:ok, objects} -> {:ok, Enum.reverse(objects)}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_objects(_objects), do: {:error, :invalid_objects}

  defp decode_object(%{"sha" => sha, "type" => type, "data" => data})
       when is_binary(sha) and is_binary(type) and is_binary(data) do
    with {:ok, type} <- decode_object_type(type),
         {:ok, data} <- Base.decode64(data) do
      {:ok, %{sha: sha, type: type, data: data}}
    else
      _ -> {:error, :invalid_objects}
    end
  end

  defp decode_object(_object), do: {:error, :invalid_objects}

  defp decode_object_type("blob"), do: {:ok, :blob}
  defp decode_object_type("tree"), do: {:ok, :tree}
  defp decode_object_type("commit"), do: {:ok, :commit}
  defp decode_object_type(_type), do: :error

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, :invalid_node}
    end
  end

  defp parents(parents) when is_list(parents) do
    if Enum.all?(parents, &is_binary/1) do
      {:ok, parents}
    else
      {:error, :invalid_parent}
    end
  end

  defp parents(_parents), do: {:error, :invalid_parent}

  defp session_metadata(nil), do: {:ok, %{}}
  defp session_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp session_metadata(_metadata), do: {:error, :invalid_session_metadata}
end
