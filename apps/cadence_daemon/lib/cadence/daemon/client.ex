defmodule Cadence.Daemon.Client do
  @moduledoc """
  Minimal HTTP/1.1 client over the daemon Unix socket.

  Used by the `mix cad.*` tasks and the daemon integration tests. Speaks raw
  HTTP over `:gen_tcp` with `Connection: close`, so responses are read until
  the server closes the socket. `request/5` accepts a per-read timeout
  (default `:infinity`); the TUI passes one so a wedged daemon cannot leak a
  task and socket on every refresh.

  A socket that is missing or has no listener raises `RuntimeError` naming the
  path and the reason. That is the normal state for the first few seconds after
  `docker run -d` (the entrypoint migrates before the daemon binds), and an
  earlier run leaves the socket file behind, so the connect fails with
  `:econnrefused` rather than `:enoent`.
  """

  def request(
        method,
        path,
        body \\ nil,
        socket_path \\ Cadence.Daemon.API.socket_path(),
        timeout \\ :infinity
      )

  def request(method, path, body, socket_path, timeout) do
    payload = body && Jason.encode!(body)
    req = build_request(method, path, payload)

    sock = connect!(socket_path)

    :ok = :gen_tcp.send(sock, req)
    response = read_all(sock, <<>>, timeout)
    :gen_tcp.close(sock)
    parse_response(response)
  end

  # Raises instead of matching on the connect result: the bare `MatchError` this
  # replaces named neither the socket nor the reason, which is useless when the
  # fix is "the daemon is still starting, retry".
  defp connect!(socket_path) do
    case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false], 5000) do
      {:ok, sock} ->
        sock

      {:error, reason} ->
        raise "cadence daemon unreachable at #{socket_path}: #{inspect(reason)}. " <>
                "Is the daemon running? A fresh `docker run -d` needs a few seconds " <>
                "to bind the socket, so retry."
    end
  end

  @doc """
  Sends a request and returns the decoded body, raising on any non-2xx response
  (using the server's `error` message when present).
  """
  def expect!(method, path, body \\ nil, socket_path \\ Cadence.Daemon.API.socket_path()) do
    case request(method, path, body, socket_path) do
      %{status: status, body: body} when status in 200..299 ->
        body

      %{body: %{"error" => error}} ->
        raise error

      %{status: status} ->
        raise "cadence daemon request failed with status #{status}"
    end
  end

  @doc """
  Resolves a project slug (or passes through an id) to a project id by asking
  `GET /projects`.
  """
  def resolve_project_id(slug_or_id, socket_path \\ Cadence.Daemon.API.socket_path()) do
    %{body: %{"projects" => projects}} = request("GET", "/projects", nil, socket_path)

    case Enum.find(projects, fn p -> p["slug"] == slug_or_id end) do
      nil -> slug_or_id
      %{"id" => id} -> id
    end
  end

  defp build_request(method, path, payload) do
    headers = [
      "#{method} #{path} HTTP/1.1\r\n",
      "Host: localhost\r\n",
      "Connection: close\r\n"
    ]

    headers =
      if payload do
        headers ++
          [
            "Content-Type: application/json\r\n",
            "Content-Length: #{byte_size(payload)}\r\n"
          ]
      else
        headers
      end

    IO.iodata_to_binary([headers, "\r\n", payload || ""])
  end

  defp read_all(sock, acc, timeout) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, data} -> read_all(sock, <<acc::binary, data::binary>>, timeout)
      {:error, :closed} -> acc
      {:error, :timeout} -> raise "cadence daemon request timed out after #{timeout} ms"
    end
  end

  defp parse_response(bin) do
    [head, body] = split_once(bin, "\r\n\r\n")
    [status_line | _] = String.split(head, "\r\n")
    [_, code | _] = String.split(status_line, " ", parts: 3)

    %{
      status: String.to_integer(code),
      body: if(body == "", do: nil, else: Jason.decode!(body))
    }
  end

  defp split_once(bin, sep) do
    case :binary.split(bin, sep) do
      [a, b] -> [a, b]
      [a] -> [a, ""]
    end
  end
end
