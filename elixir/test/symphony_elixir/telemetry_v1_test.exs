defmodule SymphonyElixir.TelemetryV1Test do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Telemetry

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
end
