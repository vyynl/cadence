defmodule Cadence.Server.Passkeys.Config do
  @moduledoc """
  Runtime configuration and boot validation for the passkey layer
  (plan §7.4, §9).

  All nine values are read from the application environment (populated from
  `CAD_WEBAUTHN_*` by `config/runtime.exs`). `validate/2` is a pure function so
  the boot guard and the unit tests exercise the same rules.

  In production `CAD_WEBAUTHN_ORIGIN` must be set explicitly: a TLS-terminating
  proxy makes the request scheme/host internal, so a derived origin would
  reject every ceremony.
  """

  @defaults [
    enabled: false,
    rp_id: "localhost",
    rp_name: "Cadence",
    origin: nil,
    user_verification: "required",
    timeout_ms: 120_000,
    max_credentials: 10,
    rate_limit: 10,
    rate_scale: 60_000
  ]

  defstruct @defaults

  @user_verification ~w(required preferred discouraged)
  @loopback_hosts ~w(localhost 127.0.0.1 ::1)
  @loopback_rp_ids ~w(localhost 127.0.0.1 ::1)
  @hostname ~r/^[a-z0-9.-]+$/
  @ipv4 ~r/^\d{1,3}(\.\d{1,3}){3}$/

  @type t :: %{
          enabled: boolean(),
          rp_id: String.t(),
          rp_name: String.t(),
          origin: String.t() | nil,
          user_verification: String.t(),
          timeout_ms: pos_integer(),
          max_credentials: pos_integer(),
          rate_limit: integer(),
          rate_scale: pos_integer()
        }

  @doc "The effective configuration, with defaults and app-env overrides."
  @spec get(keyword()) :: t()
  def get(overrides \\ []) do
    :cadence_server
    |> Application.get_env(:webauthn, [])
    |> normalize()
    |> Keyword.merge(normalize(overrides))
    |> then(&struct(__MODULE__, &1))
  end

  @doc "True when `CAD_WEBAUTHN_ENABLED=true`."
  @spec enabled?() :: boolean()
  def enabled?, do: get().enabled

  @doc """
  Validates the WebAuthn configuration. Returns `:ok` or `{:error, message}`.

  `env` is the deploy environment (`:prod`, `:dev`, `:test`). The caller raises
  with the returned message at boot.
  """
  @spec validate(map() | keyword(), atom()) :: :ok | {:error, String.t()}
  def validate(config, env \\ :dev) do
    config = normalize(config)

    with :ok <- validate_rp_id(config[:rp_id]),
         :ok <- validate_origin(config[:origin], config[:rp_id], env),
         :ok <- validate_user_verification(config[:user_verification]),
         :ok <- validate_positive(:timeout_ms, config[:timeout_ms]),
         :ok <- validate_positive(:max_credentials, config[:max_credentials]),
         :ok <- validate_integer(:rate_limit, config[:rate_limit]),
         :ok <- validate_positive(:rate_scale, config[:rate_scale]) do
      :ok
    end
  end

  @doc "Raises with the configuration error, for use at boot."
  @spec validate!(map() | keyword(), atom()) :: :ok
  def validate!(config, env \\ :dev) do
    case validate(config, env) do
      :ok ->
        :ok

      {:error, message} ->
        raise """
        Invalid WebAuthn configuration:

        #{message}

        Fix the CAD_WEBAUTHN_* variables or unset CAD_WEBAUTHN_ENABLED.
        """
    end
  end

  defp normalize(nil), do: []
  defp normalize(config) when is_map(config), do: Map.to_list(config)
  defp normalize(config) when is_list(config), do: config

  defp validate_rp_id(rp_id) when is_binary(rp_id) do
    cond do
      rp_id in @loopback_rp_ids ->
        :ok

      String.contains?(rp_id, [":", "/", "?", "#", "@", " "]) ->
        {:error, "CAD_WEBAUTHN_RP_ID must be a hostname only (no scheme, port, or path)."}

      not Regex.match?(@hostname, rp_id) ->
        {:error, "CAD_WEBAUTHN_RP_ID must be a lowercase hostname."}

      Regex.match?(@ipv4, rp_id) ->
        {:error,
         "CAD_WEBAUTHN_RP_ID must not be an IP address (only localhost/127.0.0.1/::1 are allowed)."}

      String.starts_with?(rp_id, ".") or String.ends_with?(rp_id, ".") ->
        {:error, "CAD_WEBAUTHN_RP_ID must not start or end with a dot."}

      String.contains?(rp_id, "..") ->
        {:error, "CAD_WEBAUTHN_RP_ID must not contain empty labels."}

      true ->
        :ok
    end
  end

  defp validate_rp_id(_rp_id) do
    {:error, "CAD_WEBAUTHN_RP_ID must be a hostname string."}
  end

  defp validate_origin(origin, _rp_id, env) when origin in [nil, ""] do
    if env == :prod do
      {:error, "CAD_WEBAUTHN_ORIGIN is required in production."}
    else
      {:error, "CAD_WEBAUTHN_ORIGIN is required when WebAuthn is enabled."}
    end
  end

  defp validate_origin(origin, rp_id, env) when is_binary(origin) and origin != "" do
    uri = URI.parse(origin)

    cond do
      is_nil(uri.scheme) or is_nil(uri.host) ->
        {:error,
         "CAD_WEBAUTHN_ORIGIN must be an absolute URL such as https://cadence.example.com."}

      uri.scheme not in ["http", "https"] ->
        {:error, "CAD_WEBAUTHN_ORIGIN must use http or https."}

      not is_nil(uri.userinfo) ->
        {:error, "CAD_WEBAUTHN_ORIGIN must not include user information."}

      not is_nil(uri.path) and uri.path != "" ->
        {:error, "CAD_WEBAUTHN_ORIGIN must not include a path."}

      not is_nil(uri.query) ->
        {:error, "CAD_WEBAUTHN_ORIGIN must not include a query string."}

      not is_nil(uri.fragment) ->
        {:error, "CAD_WEBAUTHN_ORIGIN must not include a fragment."}

      not host_matches_rp_id?(uri.host, rp_id) ->
        {:error,
         "CAD_WEBAUTHN_ORIGIN host #{uri.host} must equal CAD_WEBAUTHN_RP_ID (#{rp_id}) or be a subdomain of it."}

      uri.scheme == "https" ->
        :ok

      env == :prod ->
        {:error, "CAD_WEBAUTHN_ORIGIN must use https in production."}

      loopback_host?(uri.host) ->
        :ok

      true ->
        {:error, "CAD_WEBAUTHN_ORIGIN must use https unless the host is localhost."}
    end
  end

  defp validate_origin(_origin, _rp_id, _env) do
    {:error, "CAD_WEBAUTHN_ORIGIN must be a string."}
  end

  defp host_matches_rp_id?(host, rp_id) when is_binary(host) and is_binary(rp_id) do
    host == rp_id or String.ends_with?(host, "." <> rp_id)
  end

  defp host_matches_rp_id?(_host, _rp_id), do: false

  defp loopback_host?(host), do: host in @loopback_hosts

  defp validate_user_verification(value) when value in @user_verification, do: :ok

  defp validate_user_verification(_value) do
    {:error,
     "CAD_WEBAUTHN_USER_VERIFICATION must be one of #{Enum.join(@user_verification, ", ")}."}
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive(name, _value) do
    {:error, "CAD_WEBAUTHN_#{name |> to_string() |> String.upcase()} must be a positive integer."}
  end

  defp validate_integer(_name, value) when is_integer(value), do: :ok

  defp validate_integer(name, _value) do
    {:error, "CAD_WEBAUTHN_#{name |> to_string() |> String.upcase()} must be an integer."}
  end
end
