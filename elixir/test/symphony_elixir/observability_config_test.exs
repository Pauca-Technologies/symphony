defmodule SymphonyElixir.ObservabilityConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Config.Schema, Orchestrator, Telemetry}

  test "parses fleet retention, compaction, raw trace, and redaction policy" do
    assert {:ok, settings} =
             Schema.parse(%{
               "observability" => %{
                 "telemetry_retention_days" => 45,
                 "session_retention_days" => 60,
                 "raw_trace_retention_days" => 14,
                 "raw_trace_policy" => "sampled",
                 "raw_trace_sample_rate" => 0.25,
                 "raw_trace_debug" => true,
                 "session_compaction_enabled" => false,
                 "benign_notification_debug" => true,
                 "redact_fields" => ["authorization", "private_key"]
               }
             })

    assert settings.observability.telemetry_retention_days == 45
    assert settings.observability.session_retention_days == 60
    assert settings.observability.raw_trace_retention_days == 14
    assert settings.observability.raw_trace_policy == "sampled"
    assert settings.observability.raw_trace_sample_rate == 0.25
    assert settings.observability.raw_trace_debug
    refute settings.observability.session_compaction_enabled
    assert settings.observability.benign_notification_debug
    assert settings.observability.redact_fields == ["authorization", "private_key"]
  end

  test "rejects retention shorter than analytics guarantees and invalid sampling" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "observability" => %{
                 "telemetry_retention_days" => 29,
                 "session_retention_days" => 6,
                 "raw_trace_retention_days" => 6,
                 "raw_trace_sample_rate" => 2.0,
                 "raw_trace_policy" => "sometimes"
               }
             })

    assert message =~ "telemetry_retention_days"
    assert message =~ "session_retention_days"
    assert message =~ "raw_trace_retention_days"
    assert message =~ "raw_trace_sample_rate"
    assert message =~ "raw_trace_policy"
  end

  test "defaults cover common credential field names case-insensitively" do
    assert {:ok, settings} = Schema.parse(%{})

    assert Enum.all?(
             ~w(password secret client_secret private_key x-api-key),
             &(&1 in settings.observability.redact_fields)
           )
  end

  test "a run snapshots observability once across a notification burst" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    resolver = fn ->
      Agent.get_and_update(counter, &{%{redact_fields: ["secret"]}, &1 + 1})
    end

    entry =
      Enum.reduce(1..100, %{}, fn _notification, current ->
        Orchestrator.ensure_observability_policy_for_test(current, resolver)
      end)

    assert entry.observability_policy == %{redact_fields: ["secret"]}
    assert Agent.get(counter, & &1) == 1
  end

  test "benign notification logging resolves configuration once per process lifecycle" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    cache_key = {__MODULE__, System.unique_integer([:positive])}

    resolver = fn ->
      Agent.get_and_update(counter, &{%{benign_notification_debug: false}, &1 + 1})
    end

    assert Enum.all?(1..100, fn _notification ->
             not Telemetry.benign_notification_debug_for_test(cache_key, resolver)
           end)

    assert Agent.get(counter, & &1) == 1
  end
end
