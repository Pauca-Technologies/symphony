defmodule SymphonyElixir.HistoryLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Telemetry

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    Application.put_env(:symphony_elixir, :telemetry_enabled, true)
    emit_run("run-alpha", "ALPHA-1", "alpha", "implementation", "model-a", "prompt-a", "config-a", "head-a")
    emit_run("run-beta", "BETA-1", "beta", "maintenance", "model-b", "prompt-b", "config-b", "head-b")
    start_test_endpoint(orchestrator: :history_unavailable_orchestrator, snapshot_timeout_ms: 5)
    :ok
  end

  test "historical cockpit renders exact selectable windows, URL filters, and distinct outcome semantics" do
    path =
      "/history?window=30&repository=alpha&task_family=implementation&model=model-a&prompt_version=prompt-a&config_digest=config-a"

    {:ok, view, html} = live(build_conn(), path)

    assert html =~ "Historical Evaluation"
    assert html =~ "Worker-run completion"
    assert html =~ "Successful transport/runner exits, not verified task outcomes"
    assert html =~ "Material progress"
    assert html =~ "Accepted exact-head handoffs"
    assert html =~ "Post-handoff reliability"
    assert html =~ "ALPHA-1"
    refute html =~ "BETA-1"
    assert html =~ "CI"
    assert html =~ "Cost / accepted handoff"
    assert html =~ "Unavailable unless an explicit numeric cumulative USD value was emitted"
    assert html =~ "Shadow no-progress observations"
    assert html =~ "Loop alerts"
    assert html =~ "repeated_error:"
    assert html =~ "nonzero_exit:"

    assert has_element?(view, ~s(select[name="window"] option[selected][value="30"]))
    assert has_element?(view, ~s(select[name="repository"] option[selected][value="alpha"]))
    assert has_element?(view, ~s(select[name="task_family"] option[selected][value="implementation"]))
    assert has_element?(view, ~s(select[name="model"] option[selected][value="model-a"]))
    assert has_element?(view, ~s(select[name="prompt_version"] option[selected][value="prompt-a"]))
    assert has_element?(view, ~s(select[name="config_digest"] option[selected][value="config-a"]))

    assert has_element?(view, ~s(a[href*="repository=alpha"][href*="window=7"]))
    assert has_element?(view, ~s(a[href*="repository=alpha"][href*="window=30"]))
  end

  test "history stays available when the orchestrator is unavailable and rejects unsupported windows" do
    {:ok, view, html} = live(build_conn(), "/history?window=365")

    assert html =~ "Requested 7 days"
    assert html =~ "ALPHA-1"
    assert html =~ "BETA-1"
    assert has_element?(view, ~s(select[name="window"] option[selected][value="7"]))
    refute html =~ "Snapshot unavailable"
  end

  test "issue detail falls back to a dedicated historical branch without live controls or transcript claims" do
    {:ok, _view, html} = live(build_conn(), "/issues/ALPHA-1")

    assert html =~ "Symphony Historical Telemetry"
    assert html =~ "Live state is unavailable or no longer retained"
    assert html =~ "ci passed"
    assert html =~ "Historical run evidence"
    assert html =~ "Recent compact telemetry"
    assert html =~ "Shadow no-progress alerts"
    assert html =~ "material_progress:recorded"
    assert html =~ "exact_head_handoff:accepted"
    refute html =~ ~r/<h2[^>]*>Transcript<\/h2>/
    refute html =~ "Resume now"
    refute html =~ "Cancel wait"
    refute html =~ "JSON details"
    refute html =~ "Live issue detail"
  end

  test "empty malformed retained telemetry renders explicit unobserved states without crashing" do
    telemetry_dir = Application.fetch_env!(:symphony_elixir, :telemetry_dir)
    today_path = Path.join(telemetry_dir, "#{Date.to_iso8601(Date.utc_today())}.jsonl")

    File.write!(
      today_path,
      """
      not-json
      {"event":"budget_transition","transition":[]}
      {"event":"review","attestations":17,"severity_counts":"invalid"}
      """
    )

    {:ok, _view, html} = live(build_conn(), "/history?window=7")

    assert html =~ "No matching worker runs in this window."
    assert html =~ "No explicit task outcomes in this window."
    assert html =~ "CI passed"
    assert html =~ "Human review failed"
    assert html =~ "Pull requests reverted"
    assert html =~ "Unobserved in this cohort"
    assert html =~ "Shadow no-progress observations"
    assert html =~ "No reported data."
    refute html =~ "Internal Server Error"
  end

  test "renders numeric cost, prompt breakdown, extreme trajectory, and outcome-free run" do
    Telemetry.with_context(%{run_id: "run-extreme"}, fn ->
      Telemetry.emit(:run_manifest, %{
        issue_identifier: "EXTREME-1",
        repository: %{id: "alpha"},
        task: %{type: "implementation"},
        agent: %{model: "model-a"},
        prompt: %{template_sha256: "prompt-a"},
        config_digest: "config-a"
      })

      Telemetry.emit(:run_start, %{issue_identifier: "EXTREME-1", repository: "alpha"})

      Telemetry.emit(:prompt_built, %{
        issue_identifier: "EXTREME-1",
        prompt_sections: [%{id: "task_context", bytes: 10, estimated_tokens: 3}]
      })

      Telemetry.emit(:budget_transition, %{
        issue_identifier: "EXTREME-1",
        transition: %{level: "extreme"}
      })

      Telemetry.emit(:run_end, %{
        issue_identifier: "EXTREME-1",
        repository: "alpha",
        outcome: "ok",
        duration_ms: 2_000,
        cost_usd: 2.5
      })
    end)

    {:ok, _view, html} = live(build_conn(), "/history?window=7&repository=%20")

    assert html =~ "$1.25"
    assert html =~ "task_context:"
    assert html =~ "Extreme trajectories"
    assert html =~ "EXTREME-1"
    assert html =~ "none reported"
  end

  defp emit_run(run_id, identifier, repository, task, model, prompt, digest, head) do
    Telemetry.with_context(%{run_id: run_id}, fn ->
      Telemetry.emit(:run_manifest, %{
        issue_identifier: identifier,
        repository: %{id: repository, head_sha: head},
        task: %{type: task},
        agent: %{model: model},
        prompt: %{template_sha256: prompt},
        config_digest: digest
      })

      Telemetry.emit(:run_start, %{issue_identifier: identifier, repository: repository})

      Telemetry.emit(:token_high_water, %{
        issue_identifier: identifier,
        repository: repository,
        thread_id: "thread-#{run_id}",
        cumulative: %{total_tokens: 100}
      })

      Telemetry.emit(:task_outcome, %{
        outcome_version: 1,
        issue_identifier: identifier,
        stage: "material_progress",
        status: "recorded",
        authoritative: true
      })

      Telemetry.emit(:gate, %{
        issue_identifier: identifier,
        subtype: "before_handoff",
        outcome: "passed"
      })

      Telemetry.emit(:task_outcome, %{
        outcome_version: 1,
        issue_identifier: identifier,
        stage: "exact_head_handoff",
        status: "accepted",
        authoritative: true,
        exact_sha: head,
        candidate_sha: head
      })

      Telemetry.emit(:run_end, %{
        issue_identifier: identifier,
        repository: repository,
        duration_ms: 1_000,
        outcome: "ok"
      })

      if identifier == "ALPHA-1" do
        Telemetry.emit(:no_progress_loop, %{
          no_progress_version: 1,
          shadow: true,
          issue_identifier: identifier,
          decision: "alert",
          kind: "repeated_error",
          tool_class: "shell",
          result_class: "nonzero_exit",
          progress: "unchanged",
          warning_id: "npw-" <> String.duplicate("a", 24)
        })
      end
    end)

    if identifier == "ALPHA-1" do
      Telemetry.emit(:task_outcome, %{
        outcome_version: 1,
        issue_identifier: identifier,
        stage: "ci",
        status: "passed",
        authoritative: true,
        reviewed_sha: head
      })
    end
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
