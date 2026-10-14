import Config

if config_env() != :test do
  state_dir =
    System.get_env("CAD_STATE_DIR", Path.join(System.user_home!(), ".local/state/cadence"))

  config :cadence_daemon, Cadence.Daemon.Repo, database: Path.join(state_dir, "cadence.db")

  config :cadence_daemon,
    watch_debounce_ms: String.to_integer(System.get_env("CAD_WATCH_DEBOUNCE_MS", "2000")),
    watch_backend:
      (case System.get_env("CAD_WATCH_BACKEND", "fs_inotify") do
         "fs_poll" -> :fs_poll
         _ -> :fs_inotify
       end),
    local_user_id: System.get_env("CAD_LOCAL_USER_ID", "00000000-0000-0000-0000-000000000000")

  config :cadence_daemon,
    llm_timeout_ms: String.to_integer(System.get_env("CAD_LLM_TIMEOUT_MS", "5000")),
    llm_rate_limit: String.to_integer(System.get_env("CAD_LLM_RATE_LIMIT", "10")),
    llm_rate_scale: String.to_integer(System.get_env("CAD_LLM_RATE_SCALE", "60000")),
    llm_diff_max_bytes: String.to_integer(System.get_env("CAD_LLM_DIFF_MAX_BYTES", "32768")),
    llm_retry_attempts: String.to_integer(System.get_env("CAD_LLM_RETRY_ATTEMPTS", "3")),
    llm_retry_backoff_ms: String.to_integer(System.get_env("CAD_LLM_RETRY_BACKOFF_MS", "5000"))
end

config :cadence_shared, Cadence.Shared.LLM,
  provider: System.get_env("CAD_LLM_PROVIDER", "deepseek"),
  api_key: System.get_env("CAD_LLM_API_KEY"),
  model: System.get_env("CAD_LLM_MODEL", "deepseek-chat"),
  base_url: System.get_env("CAD_LLM_BASE_URL", "https://api.deepseek.com")
