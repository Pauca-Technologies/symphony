defmodule SymphonyElixir.TelemetryV1Test do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{RunManifest, Telemetry}

  test "versioned events recursively redact configured secret fields" do
    event =
      Telemetry.build_event(
        :tool,
        %{
          issue_identifier: "UDPE-7165",
          nested: %{
            "PASSWORD" => "guess-me",
            authorization: "Bearer secret",
            private_key: "pem-secret",
            safe: "kept"
          },
          token: "secret-token"
        },
        ~U[2026-08-01 12:00:00Z]
      )

    assert event["schema_version"] == 1
    assert event["event"] == "tool"
    assert event["nested"]["authorization"] == "[REDACTED]"
    assert event["nested"]["PASSWORD"] == "[REDACTED]"
    assert event["nested"]["private_key"] == "[REDACTED]"
    assert event["nested"]["safe"] == "kept"
    assert event["token"] == "[REDACTED]"
  end

  test "fleet event strings are bounded while redaction alone preserves fidelity" do
    value = String.duplicate("x", 10_000)

    assert Telemetry.redact(%{output: value}, ["secret"])["output"] == value

    event = Telemetry.build_event(:tool, %{output: value}, ~U[2026-08-01 12:00:00Z])
    assert byte_size(event["output"]) < byte_size(value)
    assert event["output"] =~ "truncated sha256="
  end

  test "fleet bounds never split a UTF-8 codepoint" do
    value = String.duplicate("a", 8_191) <> "€tail"
    event = Telemetry.build_event(:tool, %{output: value}, ~U[2026-08-01 12:00:00Z])

    assert String.valid?(event["output"])
    assert String.starts_with?(event["output"], String.duplicate("a", 8_191))
    assert event["output"] =~ "truncated sha256="
    assert {:ok, _json} = Jason.encode(event)
  end

  test "mandatory defaults redact camelCase credentials even with an empty custom list" do
    redacted =
      Telemetry.redact(
        %{
          "apiKey" => "api-secret",
          "nested" => %{
            "accessToken" => "access-secret",
            "clientSecret" => "client-secret",
            "privateKey" => "private-secret",
            "setCookie" => "cookie-secret"
          }
        },
        []
      )

    assert redacted["apiKey"] == "[REDACTED]"
    assert Enum.all?(~w(accessToken clientSecret privateKey setCookie), &(redacted["nested"][&1] == "[REDACTED]"))
    refute inspect(redacted) =~ "-secret"
  end

  test "legacy unversioned NDJSON remains readable" do
    root = Path.join(System.tmp_dir!(), "telemetry-v1-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:symphony_elixir, :telemetry_dir)
    Application.put_env(:symphony_elixir, :telemetry_dir, root)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "2026-08-01.jsonl"), Jason.encode!(%{event: "run_start"}) <> "\n")

    on_exit(fn ->
      File.rm_rf!(root)
      if previous, do: Application.put_env(:symphony_elixir, :telemetry_dir, previous), else: Application.delete_env(:symphony_elixir, :telemetry_dir)
    end)

    assert [%{"event" => "run_start", "schema_version" => 0}] =
             Telemetry.read_events(~D[2026-08-01], ~D[2026-08-01])
  end

  test "scopes run correlation to lifecycle events without leaking it to a reused process" do
    root = Path.join(System.tmp_dir!(), "telemetry-context-#{System.unique_integer([:positive])}")
    previous_dir = Application.get_env(:symphony_elixir, :telemetry_dir)
    previous_enabled = Application.get_env(:symphony_elixir, :telemetry_enabled)
    Application.put_env(:symphony_elixir, :telemetry_dir, root)
    Application.put_env(:symphony_elixir, :telemetry_enabled, true)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous_dir,
        do: Application.put_env(:symphony_elixir, :telemetry_dir, previous_dir),
        else: Application.delete_env(:symphony_elixir, :telemetry_dir)

      if is_nil(previous_enabled),
        do: Application.delete_env(:symphony_elixir, :telemetry_enabled),
        else: Application.put_env(:symphony_elixir, :telemetry_enabled, previous_enabled)
    end)

    context = %{
      run_id: "run-context",
      parent_run_id: "parent-context",
      retry_id: "retry-context",
      retry_attempt: 4,
      attempt: 4
    }

    Telemetry.with_context(context, fn ->
      Telemetry.emit(:budget_transition, %{issue_id: "issue-context"})
      Telemetry.emit(:review, %{issue_id: "issue-context", thread_id: "review-thread"})
      Telemetry.emit(:lifecycle, %{issue_id: "issue-context", phase: "waiting"})
      Telemetry.emit(:failure, %{issue_id: "issue-context", failure_class: "transient"})
    end)

    assert Telemetry.current_context() == %{}
    Telemetry.emit(:failure, %{issue_id: "unrelated-issue"})

    events = Telemetry.read_events(Date.utc_today(), Date.utc_today())
    correlated = Enum.filter(events, &(&1["issue_id"] == "issue-context"))
    assert Enum.map(correlated, & &1["event"]) == ~w(budget_transition review lifecycle failure)

    assert Enum.all?(correlated, fn event ->
             event["run_id"] == "run-context" and event["parent_run_id"] == "parent-context" and
               event["retry_id"] == "retry-context" and event["retry_attempt"] == 4 and
               event["attempt"] == 4
           end)

    unrelated = Enum.find(events, &(&1["issue_id"] == "unrelated-issue"))
    refute Map.has_key?(unrelated, "run_id")
  end

  test "configuration digests use canonical map ordering" do
    left = %{sandbox: %{mode: "workspace-write", paths: ["a", "b"]}, model: "gpt-test"}
    right = %{"model" => "gpt-test", "sandbox" => %{"paths" => ["a", "b"], "mode" => "workspace-write"}}

    assert RunManifest.config_digest(left) == RunManifest.config_digest(right)
  end
end
