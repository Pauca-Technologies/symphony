import Config

config :phoenix, :json_library, Jason

test_runtime_root = Path.join(System.tmp_dir!(), "symphony-elixir-test-runtime")

config :symphony_elixir,
  persistent_workers_enabled: config_env() != :test,
  drain_state_path: if(config_env() == :test, do: Path.join(test_runtime_root, "drain-state.json"), else: nil),
  wait_state_path: if(config_env() == :test, do: Path.join(test_runtime_root, "waits.json"), else: nil),
  wait_state_reset_on_start: config_env() == :test,
  linear_rate_limit_state_root: if(config_env() == :test, do: Path.join(test_runtime_root, "linear-rate-limit"), else: nil),
  persistent_worker_registry_root: if(config_env() == :test, do: Path.join(test_runtime_root, "workers"), else: nil),
  persistent_worker_log_root: if(config_env() == :test, do: Path.join(test_runtime_root, "worker-logs"), else: nil)

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false
