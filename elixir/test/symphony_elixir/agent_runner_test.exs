defmodule SymphonyElixir.AgentRunnerTest.Fix2AbnormalBackend do
  @moduledoc false
  # A backend whose turn completes abnormally *after* the agent captured a
  # deferred In Review handoff — the case where a silent drop both skips the
  # handoff and (pre-fix) fed the orchestrator claim leak. Seeds the captured
  # request the test prepared, then reports the abnormal completion.
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, _prompt, _issue, _opts) do
    request = Application.fetch_env!(:symphony_elixir, :fix2_deferred_request)
    SymphonyElixir.AgentRunner.store_deferred_review_handoff_for_test(request)
    {:error, {:turn_completed_abnormally, %{stop_reason: "interrupted"}}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.DeferredBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, _prompt, _issue, _opts) do
    :symphony_elixir
    |> Application.fetch_env!(:deferred_requests_for_test)
    |> Enum.each(&SymphonyElixir.AgentRunner.store_deferred_review_handoff_for_test/1)

    {:ok, %{session_id: "deferred-test-session"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.BlockingDeferredBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, _prompt, _issue, _opts) do
    request = Application.fetch_env!(:symphony_elixir, :blocking_deferred_request_for_test)
    recipient = Application.fetch_env!(:symphony_elixir, :blocking_deferred_recipient_for_test)
    SymphonyElixir.AgentRunner.store_deferred_review_handoff_for_test(request)
    send(recipient, {:implementor_turn_ready, self()})

    receive do
      :finish_implementor_turn -> {:ok, %{session_id: "blocking-deferred-session"}}
    end
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.TurnCountingBackend do
  @moduledoc false
  # Records every turn it runs so a test can assert how many continuation turns
  # the loop actually drove. Each turn completes normally.
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, _prompt, _issue, _opts) do
    recipient = Application.fetch_env!(:symphony_elixir, :turn_count_recipient_for_test)
    send(recipient, :turn_ran)
    {:ok, %{session_id: "turn-counting-session"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.ManifestOrderingBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, _prompt, _issue, _opts) do
    events =
      SymphonyElixir.Telemetry.read_events(
        Date.utc_today(),
        Date.utc_today()
      )

    send(
      Application.fetch_env!(:symphony_elixir, :manifest_ordering_recipient),
      {:events_before_agent_turn, events}
    )

    {:ok, %{session_id: "manifest-ordering-session"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.RepositoryProgressBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(workspace, _opts), do: {:ok, %{workspace: workspace, worker_host: nil}}

  @impl true
  def run_turn(%{workspace: workspace}, _prompt, _issue, _opts) do
    case Application.fetch_env!(:symphony_elixir, :repository_progress_action) do
      :append_then_error ->
        File.write!(Path.join(workspace, "progress.txt"), "agent change\n", [:append])
        {:error, :forced_turn_failure}

      :break_post_probe ->
        File.rename!(Path.join(workspace, ".git"), Path.join(workspace, ".git-hidden"))
        {:ok, %{session_id: "broken-post-probe"}}

      {:fail_hash_probe, probe_state} ->
        Agent.update(probe_state, fn _previous -> :fail end)
        {:ok, %{session_id: "failed-content-probe"}}
    end
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.ResumePacketErrorBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(workspace, _opts), do: {:ok, %{worker_host: nil, workspace: workspace}}

  @impl true
  def run_turn(session, prompt, _issue, _opts) do
    send(Application.fetch_env!(:symphony_elixir, :resume_packet_error_recipient), {:resume_packet_error_prompt, prompt})

    send(
      Application.fetch_env!(:symphony_elixir, :resume_packet_error_recipient),
      {:resume_packet_error_pre_turn_packet, SymphonyElixir.Workspace.load_resume_packet(session.workspace)}
    )

    {:error, :handled_resume_packet_error}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.ResumePacketProbeBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(workspace, _opts), do: {:ok, %{worker_host: nil, workspace: workspace}}

  @impl true
  def run_turn(session, prompt, issue, _opts) do
    recipient = Application.fetch_env!(:symphony_elixir, :resume_packet_probe_recipient)
    probe_state = Application.fetch_env!(:symphony_elixir, :resume_packet_probe_state)
    turn = Process.get(:resume_packet_probe_turn, 0) + 1
    Process.put(:resume_packet_probe_turn, turn)
    head_calls = Agent.get(probe_state, & &1.head_calls)
    packet = SymphonyElixir.Workspace.load_resume_packet(session.workspace)
    send(recipient, {:resume_packet_probe_turn, turn, head_calls, prompt, issue, packet})
    {:ok, %{session_id: "resume-packet-probe-#{turn}"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.WaitingBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, prompt, _issue, opts) do
    recipient = Application.fetch_env!(:symphony_elixir, :waiting_backend_recipient)
    send(recipient, {:waiting_prompt, prompt})

    result =
      Keyword.fetch!(opts, :tool_executor).(
        "wait_for",
        %{
          "reason" => "GitHub Actions is degraded",
          "condition" => %{"type" => "github_actions_recovered"}
        }
      )

    send(recipient, {:waiting_tool_result, result})
    {:ok, %{session_id: "waiting-session"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.HandoffToolBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, _prompt, _issue, opts) do
    result =
      Keyword.fetch!(opts, :tool_executor).(
        "linear_issue",
        %{
          "operation" => "transition",
          "state" => "In Review"
        }
      )

    send(Application.fetch_env!(:symphony_elixir, :handoff_tool_recipient), {
      :handoff_tool_result,
      result
    })

    {:ok, %{session_id: "handoff-tool-session"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.PendingGateBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, prompt, _issue, _opts) do
    recipient = Application.fetch_env!(:symphony_elixir, :pending_gate_recipient_for_test)
    turn = Process.get(:pending_gate_turn, 0) + 1
    Process.put(:pending_gate_turn, turn)
    send(recipient, {:pending_gate_turn, turn, prompt})

    if turn == 1 do
      request = Application.fetch_env!(:symphony_elixir, :pending_gate_request_for_test)
      :ok = SymphonyElixir.AgentRunner.store_deferred_handoff_gate_for_test(request)
    end

    {:ok, %{session_id: "pending-gate-session-#{turn}"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.HandoffPromptBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, prompt, issue, _opts) do
    recipient = Application.fetch_env!(:symphony_elixir, :handoff_prompt_recipient_for_test)
    send(recipient, {:handoff_prompt, prompt, issue})

    {:ok, %{session_id: "handoff-prompt-session"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.EfficiencyBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, prompt, _issue, opts) do
    recipient = Application.fetch_env!(:symphony_elixir, :efficiency_recipient_for_test)
    turn = Process.get(:efficiency_turn, 0) + 1
    Process.put(:efficiency_turn, turn)
    send(recipient, {:efficiency_prompt, turn, prompt})

    on_message = Keyword.fetch!(opts, :on_message)
    on_message.(%{event: :session_started, thread_id: "parent-thread", timestamp: DateTime.utc_now()})

    on_message.(%{
      event: :token_usage,
      thread_id: "parent-thread",
      timestamp: DateTime.utc_now(),
      usage: %{input_tokens: 80 + turn * 20, output_tokens: 20, total_tokens: 100 + turn * 20}
    })

    {:ok, %{session_id: "efficiency-session-#{turn}"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.BudgetStressBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, _prompt, _issue, opts) do
    owner = Application.fetch_env!(:symphony_elixir, :budget_stress_owner_for_test)
    volume = Application.fetch_env!(:symphony_elixir, :budget_stress_volume_for_test)
    on_message = Keyword.fetch!(opts, :on_message)

    on_message.(%{event: :session_started, thread_id: "parent-thread", timestamp: DateTime.utc_now()})

    Enum.each(1..volume, fn sequence ->
      {thread_id, cumulative} =
        if rem(sequence, 2) == 1,
          do: {"parent-thread", div(sequence + 1, 2)},
          else: {"delegated-thread", div(sequence, 2)}

      on_message.(%{
        event: :token_usage,
        thread_id: thread_id,
        usage: %{input_tokens: cumulative, output_tokens: 0, total_tokens: cumulative}
      })
    end)

    {:message_queue_len, queue_len} = Process.info(self(), :message_queue_len)
    send(owner, {:budget_stress_runner_queue_len, queue_len})
    {:ok, %{session_id: "budget-stress-session"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.BudgetRuntimeRecipient do
  @moduledoc false
  use GenServer

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  @impl true
  def init(owner), do: {:ok, owner}

  @impl true
  def handle_info({:worker_runtime_info, issue_id, %{budget_metrics: _metrics} = info}, owner) do
    send(owner, {:budget_runtime_info, issue_id, info})
    {:noreply, owner}
  end

  def handle_info(_message, owner), do: {:noreply, owner}
end

defmodule SymphonyElixir.AgentRunnerTest.LifecycleRecipient do
  @moduledoc false
  use GenServer

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  @impl true
  def init(owner), do: {:ok, owner}

  @impl true
  def handle_call(message, _from, owner) do
    send(owner, {:lifecycle_call, message})
    {:reply, :ok, owner}
  end

  @impl true
  def handle_info(message, owner) do
    send(owner, {:lifecycle_info, message})
    {:noreply, owner}
  end
end

defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  defp write_review_verdict(ctx, verdict) do
    exact =
      Map.merge(
        %{
          "packet_id" => ctx.packet.packet_id,
          "reviewed_sha" => ctx.reviewed_sha,
          "inspected" => ["authoritative full diff"],
          "attestations" => %{"reused" => [], "rerun" => []},
          "full_diff_inspected" => true
        },
        verdict
      )

    File.mkdir_p!(Path.dirname(ctx.verdict_path))
    File.write!(ctx.verdict_path, Jason.encode!(exact))
  end

  alias SymphonyElixir.{AgentRunner, ResumePacket, RunManifest, Telemetry}
  alias SymphonyElixir.AgentRunnerTest.BlockingDeferredBackend
  alias SymphonyElixir.AgentRunnerTest.BudgetRuntimeRecipient
  alias SymphonyElixir.AgentRunnerTest.BudgetStressBackend
  alias SymphonyElixir.AgentRunnerTest.DeferredBackend
  alias SymphonyElixir.AgentRunnerTest.EfficiencyBackend
  alias SymphonyElixir.AgentRunnerTest.Fix2AbnormalBackend
  alias SymphonyElixir.AgentRunnerTest.HandoffPromptBackend
  alias SymphonyElixir.AgentRunnerTest.HandoffToolBackend
  alias SymphonyElixir.AgentRunnerTest.LifecycleRecipient
  alias SymphonyElixir.AgentRunnerTest.ManifestOrderingBackend
  alias SymphonyElixir.AgentRunnerTest.PendingGateBackend
  alias SymphonyElixir.AgentRunnerTest.RepositoryProgressBackend
  alias SymphonyElixir.AgentRunnerTest.ResumePacketErrorBackend
  alias SymphonyElixir.AgentRunnerTest.ResumePacketProbeBackend
  alias SymphonyElixir.AgentRunnerTest.TurnCountingBackend
  alias SymphonyElixir.AgentRunnerTest.WaitingBackend
  alias SymphonyElixir.Linear.Comment
  alias SymphonyElixir.Linear.Issue

  @idempotency_label "symphony:routing-warned"
  @needs_human_input_label "needs-human-input"
  @blocked_marker "<!-- symphony:blocked-on-giveup -->"

  setup do
    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_available_labels, :all)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_available_labels)
    end)

    :ok
  end

  test "emits one correlated manifest after routing and before the first agent turn" do
    Application.put_env(:symphony_elixir, :telemetry_enabled, true)
    Application.put_env(:symphony_elixir, :manifest_ordering_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :manifest_ordering_recipient)
    end)

    issue = %Issue{
      id: "issue-run-manifest",
      identifier: "UDPE-7500",
      title: "Add reproducible run identifiers",
      state: "In Progress",
      labels: ["repo:symphony"]
    }

    workflow = %{
      prompt_template: "consumer-owned prompt that is hashed, not persisted",
      config: %{}
    }

    assert :ok =
             AgentRunner.run_codex_turns_for_test(
               "/tmp",
               issue,
               nil,
               [
                 agent_backend: {ManifestOrderingBackend, %{model: "test-model", reasoning_effort: "high"}},
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 per_repo_workflow: workflow,
                 workflow_source: "repository:WORKFLOW.md",
                 repository_id: "symphony",
                 repository_manifest: %{
                   head_sha: "head-sha",
                   base_sha: "base-sha",
                   candidate_base_sha: "candidate-base-sha",
                   dirty: false
                 },
                 run_id: "run-7500",
                 parent_run_id: "run-7499",
                 retry_id: "retry-7500",
                 attempt: 3,
                 max_turns: 1
               ],
               nil
             )

    assert_receive {:events_before_agent_turn, events}
    event_names = Enum.map(events, & &1["event"])
    assert Enum.count(event_names, &(&1 == "run_manifest")) == 1

    routing_index = Enum.find_index(event_names, &(&1 == "routing_decision"))
    manifest_index = Enum.find_index(event_names, &(&1 == "run_manifest"))
    prompt_index = Enum.find_index(event_names, &(&1 == "prompt_built"))
    assert routing_index < manifest_index
    assert manifest_index < prompt_index

    manifest = Enum.find(events, &(&1["event"] == "run_manifest"))
    assert manifest["manifest_version"] == 1
    assert manifest["run_id"] == "run-7500"
    assert manifest["parent_run_id"] == "run-7499"
    assert manifest["retry_id"] == "retry-7500"
    assert manifest["retry_attempt"] == 3
    assert manifest["attempt"] == 3
    assert manifest["repository"]["head_sha"] == "head-sha"
    assert manifest["agent"]["model"] == "test-model"
    assert manifest["agent"]["reasoning_effort"] == "high"
    assert manifest["workflow"]["source"] == "repository:WORKFLOW.md"
    assert manifest["configuration"]["workflow"] == manifest["workflow"]

    assert manifest["configuration"]["prompt"]["template_sha256"] ==
             manifest["prompt"]["template_sha256"]

    assert manifest["prompt"]["composition_version"] == "prompt-sections/v1"

    assert manifest["prompt"]["section_hashes"] == %{
             "availability" => "per_turn",
             "event" => "prompt_built",
             "field" => "injected_section_hashes"
           }

    assert manifest["config_digest"] =~ ~r/^[0-9a-f]{64}$/

    changed_prompt_configuration =
      put_in(
        manifest,
        ["configuration", "prompt", "template_sha256"],
        String.duplicate("0", 64)
      )["configuration"]

    refute RunManifest.config_digest(changed_prompt_configuration) == manifest["config_digest"]
    refute inspect(manifest) =~ workflow.prompt_template

    correlated = Enum.filter(events, &(&1["event"] in ~w(routing_decision run_manifest prompt_built)))

    assert Enum.all?(correlated, fn event ->
             event["run_id"] == "run-7500" and event["parent_run_id"] == "run-7499" and
               event["retry_id"] == "retry-7500" and event["retry_attempt"] == 3
           end)
  end

  test "collects repository provenance when no runtime-info recipient is present" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-manifest-nil-recipient-#{System.unique_integer([:positive])}"
      )

    origin = Path.join(root, "origin")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(origin)
    on_exit(fn -> File.rm_rf(root) end)

    System.cmd("git", ["-C", origin, "init", "--quiet", "--initial-branch", "main"])
    System.cmd("git", ["-C", origin, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", origin, "config", "user.email", "test@example.com"])
    File.write!(Path.join(origin, "WORKFLOW.md"), "Repository workflow for provenance.\n")
    System.cmd("git", ["-C", origin, "add", "WORKFLOW.md"])
    System.cmd("git", ["-C", origin, "commit", "--quiet", "-m", "initial"])
    {expected_head, 0} = System.cmd("git", ["-C", origin, "rev-parse", "HEAD"])

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    File.write!(
      Application.fetch_env!(:symphony_elixir, :repo_config_path),
      """
      linear:
        team_id: UDPE
      repos:
        - id: manifest-repo
          label: repo:manifest-repo
          repo_url: #{origin}
          workflow_path: WORKFLOW.md
          base_branch: main
      """
    )

    Application.put_env(:symphony_elixir, :telemetry_enabled, true)
    Application.put_env(:symphony_elixir, :manifest_ordering_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :manifest_ordering_recipient)
    end)

    issue = %Issue{
      id: "issue-manifest-nil-recipient",
      identifier: "UDPE-7500-NIL",
      title: "Capture repository state without a recipient",
      state: "In Progress",
      labels: ["repo:manifest-repo"],
      comments: []
    }

    assert :ok =
             AgentRunner.run(issue, nil,
               agent_backend: {ManifestOrderingBackend, %{}},
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
               max_turns: 1
             )

    assert_receive {:events_before_agent_turn, events}
    manifest = Enum.find(events, &(&1["event"] == "run_manifest"))
    assert manifest["repository"]["id"] == "manifest-repo"
    assert manifest["repository"]["head_sha"] == String.trim(expected_head)
    assert manifest["repository"]["dirty"] == false
  end

  test "records dirty-to-dirty material progress even when the handled turn returns an error" do
    {issue, _workspace_root} = prepare_progress_repository!("UDPE-PROGRESS-ERROR")
    Application.put_env(:symphony_elixir, :repository_progress_action, :append_then_error)
    Application.put_env(:symphony_elixir, :telemetry_enabled, true)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :repository_progress_action) end)

    assert_raise RuntimeError, ~r/forced_turn_failure/, fn ->
      AgentRunner.run(issue, nil,
        agent_backend: {RepositoryProgressBackend, %{}},
        issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
        max_turns: 1
      )
    end

    outcomes =
      Date.utc_today()
      |> then(&SymphonyElixir.Telemetry.read_events(&1, &1))
      |> Enum.filter(&(&1["event"] == "task_outcome"))

    assert [progress] = outcomes
    assert progress["stage"] == "material_progress"
    assert progress["status"] == "recorded"
    assert progress["run_id"] =~ ~r/^[0-9a-f-]{36}$/
    assert progress["before_worktree_fingerprint"] =~ ~r/^[0-9a-f]{64}$/
    assert progress["after_worktree_fingerprint"] =~ ~r/^[0-9a-f]{64}$/
    refute progress["before_worktree_fingerprint"] == progress["after_worktree_fingerprint"]
    assert progress["workspace_dirty"]
  end

  test "does not record progress when only the post-run repository probe fails" do
    {issue, workspace_root} = prepare_progress_repository!("UDPE-PROGRESS-PROBE")
    Application.put_env(:symphony_elixir, :repository_progress_action, :break_post_probe)
    Application.put_env(:symphony_elixir, :telemetry_enabled, true)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :repository_progress_action) end)

    assert :ok =
             AgentRunner.run(issue, nil,
               agent_backend: {RepositoryProgressBackend, %{}},
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
               max_turns: 1
             )

    events = SymphonyElixir.Telemetry.read_events(Date.utc_today(), Date.utc_today())
    refute Enum.any?(events, &(&1["event"] == "task_outcome" and &1["stage"] == "material_progress"))
    assert Enum.any?(events, &(&1["event"] == "resume_packet_error" and &1["error_code"] == "repository.head_unavailable"))

    workspace = Path.join(workspace_root, "UDPE-PROGRESS-PROBE")
    assert {:ok, packet} = Workspace.load_resume_packet(workspace)
    assert packet["repository"]["availability"] == "stale"
    assert packet["repository"]["source"] == "persisted:#{packet["previous_packet_id"]}"
    assert "repository.head_unavailable" in packet["errors"]["codes"]
  end

  test "does not record progress when only the post-run content hash probe fails" do
    {issue, _workspace_root} = prepare_progress_repository!("UDPE-PROGRESS-HASH-PROBE")
    {:ok, probe_state} = Agent.start_link(fn -> :ok end)

    git_runner = fn
      ["hash-object" | _rest] = args, workspace ->
        if Agent.get(probe_state, & &1) == :fail,
          do: {"transient hash failure", 17},
          else: System.cmd("git", args, cd: workspace, stderr_to_stdout: true)

      args, workspace ->
        System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    end

    Application.put_env(
      :symphony_elixir,
      :repository_progress_action,
      {:fail_hash_probe, probe_state}
    )

    Application.put_env(:symphony_elixir, :telemetry_enabled, true)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :repository_progress_action)
      if Process.alive?(probe_state), do: Agent.stop(probe_state)
    end)

    assert :ok =
             AgentRunner.run(issue, nil,
               agent_backend: {RepositoryProgressBackend, %{}},
               repository_git_runner: git_runner,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
               max_turns: 1
             )

    events = SymphonyElixir.Telemetry.read_events(Date.utc_today(), Date.utc_today())
    refute Enum.any?(events, &(&1["event"] == "task_outcome" and &1["stage"] == "material_progress"))
  end

  test "resume packets use one post-turn repository collection and remain the final prompt section" do
    Application.put_env(:symphony_elixir, :telemetry_enabled, true)
    Application.put_env(:symphony_elixir, :resume_packet_probe_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :resume_packet_probe_recipient)
      Application.delete_env(:symphony_elixir, :resume_packet_probe_state)
    end)

    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-runner-resume-packet-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{
      id: "issue-resume-packet-turns",
      identifier: "UDPE-7502-TURNS",
      title: "Keep continuation state deterministic",
      state: "In Progress",
      labels: ["repo:symphony"],
      comments: [
        %Comment{id: "workpad-resume", body: "## Codex Workpad\n### Plan\n- [ ] finish integration"}
      ]
    }

    assert {:ok, workspace} = Workspace.create_for_issue(issue)
    File.write!(Workspace.resume_packet_path(workspace), "corrupt legacy packet")
    {git_runner, probe_state} = counting_manifest_runner(workspace, fail_head_calls: [1])
    Application.put_env(:symphony_elixir, :resume_packet_probe_state, probe_state)

    on_exit(fn ->
      if Process.alive?(probe_state), do: Agent.stop(probe_state)
      File.rm_rf(workspace_root)
    end)

    fetcher = fn [_issue_id] ->
      count = Process.get(:resume_packet_fetch_count, 0) + 1
      Process.put(:resume_packet_fetch_count, count)
      state = if count == 1, do: "In Progress", else: "Done"
      {:ok, [%{issue | state: state}]}
    end

    initial_manifest = %{
      head_sha: String.duplicate("a", 40),
      base_sha: nil,
      candidate_base_sha: nil,
      actual_paths: ["lib/path-1.ex"],
      dirty: true,
      diff_counts: %{files: 1, additions: 1, deletions: 0},
      worktree_status_fingerprint: String.duplicate("1", 64),
      worktree_content_fingerprint: String.duplicate("2", 64),
      worktree_fingerprint_complete: true,
      errors: []
    }

    assert :ok =
             AgentRunner.run_codex_turns_for_test(
               workspace,
               issue,
               self(),
               [
                 agent_backend: {ResumePacketProbeBackend, %{}},
                 issue_state_fetcher: fetcher,
                 repository_manifest: initial_manifest,
                 repository_git_runner: git_runner,
                 resume_verification: %{
                   source: "symphony:test_gate",
                   exact_sha: String.duplicate("b", 40),
                   gate_status: "passed",
                   evidence_refs: [
                     ".artifacts/before-handoff/result.json",
                     "gate:raw\nRESUME_PACKET_INJECTION",
                     "/tmp/raw-command-output.txt"
                   ],
                   checks: [
                     %{
                       name: "make all",
                       status: "passed",
                       sha: String.duplicate("b", 40),
                       evidence_ref: "gate:job-7502"
                     },
                     %{
                       name: "unsafe check\nRESUME_PACKET_INJECTION",
                       status: "failed\nraw output",
                       sha: String.duplicate("b", 40),
                       evidence_ref: "gate:unsafe\nraw-output"
                     }
                   ]
                 },
                 run_id: "run-resume-packet",
                 retry_attempt: 0,
                 max_turns: 2
               ],
               nil
             )

    assert_receive {:resume_packet_probe_turn, 1, 0, first_prompt, ^issue, {:ok, first_turn_packet}}

    assert_receive {:resume_packet_probe_turn, 2, 1, continuation_prompt, _refreshed_issue, {:ok, second_turn_packet}}

    assert first_turn_packet["repository"]["source"] == "host:git"
    assert second_turn_packet["repository"]["availability"] == "stale"

    assert second_turn_packet["repository"]["source"] ==
             "persisted:#{second_turn_packet["previous_packet_id"]}"

    Enum.each([first_prompt, continuation_prompt], fn prompt ->
      assert length(:binary.matches(prompt, "Symphony status/resume packet v1")) == 1
    end)

    assert first_prompt =~ "resume_packet_invalid"
    refute continuation_prompt =~ "resume_packet_invalid"
    assert continuation_prompt =~ "repository.head_unavailable"

    assert prompt_position(first_prompt, "Symphony status/resume packet v1") >
             prompt_position(first_prompt, "Symphony waiting requirement:")

    assert prompt_position(continuation_prompt, "Symphony status/resume packet v1") >
             prompt_position(continuation_prompt, "Continuation guidance:")

    probes = Agent.get(probe_state, & &1)
    assert probes.head_calls == 2
    assert probes.numstat_calls == 2
    assert probes.numstat_path_counts == [50, 50]
    assert Enum.all?(probes.cwds, &(&1 == workspace))
    refute Enum.any?(probes.cwds, &(&1 == File.cwd!()))

    assert {:ok, final_packet} = Workspace.load_resume_packet(workspace)
    assert final_packet["boundary"]["reason"] == "turn_terminal"
    assert final_packet["turns"]["current"] == 2
    assert final_packet["budget"]["availability"] == "current"
    assert final_packet["verification"]["current_head_status"] == "current"
    refute "resume_packet_invalid" in final_packet["errors"]["codes"]
    refute "repository.head_unavailable" in final_packet["errors"]["codes"]

    assert [%{"name" => "make all", "status" => "passed", "head_status" => "current"}] =
             Enum.map(
               final_packet["verification"]["check_summaries"],
               &Map.take(&1, ~w(name status head_status))
             )

    assert final_packet["repository"]["diff_files"] == 50
    assert final_packet["repository"]["diff_additions"] == 50

    events = Telemetry.read_events(Date.utc_today(), Date.utc_today())
    resume_events = Enum.filter(events, &(&1["event"] == "resume_packet"))

    assert Enum.map(resume_events, & &1["resume_packet_boundary"]) ==
             ~w(turn_start turn_complete turn_start turn_terminal)

    assert Enum.all?(resume_events, fn event ->
             is_binary(event["resume_packet_id"]) and is_binary(event["resume_packet_sha256"]) and
               is_binary(event["resume_packet_ref"]) and
               not String.contains?(event["resume_packet_ref"], "/") and
               ".artifacts/before-handoff/result.json" in event["resume_packet_evidence_refs"] and
               "gate:job-7502" in event["resume_packet_evidence_refs"] and
               Enum.all?(event["resume_packet_evidence_refs"], fn reference ->
                 not String.contains?(reference, ["\n", "\r", "RESUME_PACKET_INJECTION", "/tmp/"])
               end) and
               not Map.has_key?(event, "resume_packet")
           end)

    prompt_events = Enum.filter(events, &(&1["event"] == "prompt_built"))
    assert length(prompt_events) == 2

    assert Enum.all?(prompt_events, fn event ->
             List.last(event["prompt_sections"])["id"] == "continuation.status_resume_packet" and
               is_binary(event["injected_section_hashes"]["continuation.status_resume_packet"])
           end)

    refute inspect(events) =~ "Symphony status/resume packet v1"
    refute inspect(events) =~ "RESUME_PACKET_INJECTION"
    refute inspect(events) =~ "/tmp/raw-command-output.txt"
    assert Enum.any?(events, &(&1["event"] == "resume_packet_error" and &1["error_code"] == "resume_packet_invalid"))
  end

  test "handled turn errors still refresh and persist one post-turn resume packet" do
    Application.put_env(:symphony_elixir, :resume_packet_error_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :resume_packet_error_recipient) end)

    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-runner-error-packet-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{
      id: "issue-resume-packet-error",
      identifier: "UDPE-7502-ERROR",
      title: "Persist handled failures",
      state: "In Progress",
      comments: []
    }

    assert {:ok, workspace} = Workspace.create_for_issue(issue)
    {git_runner, probe_state} = counting_manifest_runner(workspace)

    old_packet =
      ResumePacket.build(
        %{
          identity: %{run_id: "old-run", retry_attempt: 9},
          repository: %{head_sha: String.duplicate("a", 40), dirty: true},
          budget: %{metrics: %{total_tokens: 999}, thresholds: %{total_tokens: 1_000}},
          boundary_reason: :retry_scheduled
        },
        now: ~U[2026-09-02 09:00:00Z]
      )

    assert :ok = Workspace.persist_resume_packet(workspace, old_packet)

    on_exit(fn ->
      if Process.alive?(probe_state), do: Agent.stop(probe_state)
      File.rm_rf(workspace_root)
    end)

    assert {:error, :handled_resume_packet_error} =
             AgentRunner.run_codex_turns_for_test(
               workspace,
               issue,
               nil,
               [
                 agent_backend: {ResumePacketErrorBackend, %{}},
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end,
                 repository_manifest: %{
                   head_sha: String.duplicate("a", 40),
                   actual_paths: ["lib/path-1.ex"],
                   dirty: true,
                   worktree_status_fingerprint: String.duplicate("1", 64),
                   errors: []
                 },
                 repository_git_runner: git_runner,
                 per_repo_workflow: %{
                   prompt_template: "Repository test workflow.",
                   config: %{"agent" => %{"efficiency" => %{"capsule_max_bytes" => 512}}}
                 },
                 run_id: "new-error-run",
                 parent_run_id: "old-run",
                 retry_attempt: 10,
                 budget_snapshotter: fn _collector -> exit(:transient_snapshot_failure) end,
                 max_turns: 1
               ],
               nil
             )

    assert_receive {:resume_packet_error_prompt, prompt}
    assert_receive {:resume_packet_error_pre_turn_packet, {:ok, pre_turn_packet}}
    assert "budget.snapshot_failed" in pre_turn_packet["errors"]["codes"]
    assert pre_turn_packet["budget"]["availability"] == "stale"
    assert pre_turn_packet["budget"]["metrics"]["total_tokens"] == 999
    assert length(:binary.matches(prompt, "Symphony status/resume packet v1")) == 1
    assert prompt =~ "run_id=new-error-run"
    refute prompt =~ "Run: run_id=old-run"
    status_offset = prompt_position(prompt, "Symphony status/resume packet v1")
    assert byte_size(binary_part(prompt, status_offset, byte_size(prompt) - status_offset)) <= 512

    probes = Agent.get(probe_state, & &1)
    assert probes.head_calls == 1
    assert probes.numstat_calls == 1

    assert {:ok, packet} = Workspace.load_resume_packet(workspace)
    assert packet["boundary"]["reason"] == "turn_error"
    assert packet["turns"]["current"] == 1
    assert packet["run"]["run_id"] == "new-error-run"
    assert packet["run"]["parent_run_id"] == "old-run"
    assert packet["budget"]["metrics"]["total_tokens"] == 0
    refute "budget.snapshot_failed" in packet["errors"]["codes"]
  end

  test "builds safe manifest policies for alternate backends and reviewer workflows" do
    issue = %Issue{
      id: "issue-manifest-backends",
      identifier: "UDPE-7500-BACKENDS",
      title: "Capture alternate backend policy",
      labels: ["repo:alternate"]
    }

    acp_route = %{
      backend: SymphonyElixir.Acp.Client,
      overrides: %{model: "acp-model"},
      profile: "alternate",
      source: :injected
    }

    assert {:ok, efficiency} =
             SymphonyElixir.AgentEfficiency.decide(issue, acp_route, %{config: %{}})

    identity = RunManifest.execution_identity(nil)
    assert identity.attempt == nil
    assert identity.retry_attempt == 0

    context = %{
      identity: identity,
      issue: issue,
      route: acp_route,
      efficiency: efficiency,
      settings: Config.settings!(),
      workspace: "/tmp",
      repo_workflow: %{prompt_template: "implementation workflow"},
      review_workflow: %{prompt_template: "reviewer workflow", config: %{}}
    }

    acp_manifest = RunManifest.build(context)
    assert acp_manifest.repository.id == "alternate"
    assert acp_manifest.approval == %{auto_approve: context.settings.acp.auto_approve}
    assert acp_manifest.sandbox.advertise_fs == context.settings.acp.advertise_fs
    assert acp_manifest.workflow.review_prompt_template_sha256 =~ ~r/^[0-9a-f]{64}$/

    claude_manifest =
      RunManifest.build(%{
        context
        | route: %{acp_route | backend: SymphonyElixir.ClaudeCode.Client}
      })

    assert claude_manifest.approval == %{
             permission_mode: context.settings.claude_code.permission_mode
           }

    assert claude_manifest.sandbox == nil

    codex_manifest =
      RunManifest.build(%{
        context
        | issue: %{issue | labels: ["unrelated", "repo:alternate"]},
          route: %{acp_route | backend: SymphonyElixir.Codex.AppServer},
          repo_workflow: nil
      })

    assert codex_manifest.approval == context.settings.codex.approval_policy
    assert codex_manifest.sandbox.thread == context.settings.codex.thread_sandbox
    assert codex_manifest.prompt.template_sha256 =~ ~r/^[0-9a-f]{64}$/

    fallback_repository =
      context
      |> Map.put(:issue, %{id: "map-issue", identifier: "UDPE-MAP"})
      |> Map.put(:repository_id, nil)
      |> RunManifest.build()

    assert fallback_repository.repository.id == "default"
    assert RunManifest.config_digest(%{date: ~D[2026-09-02]}) =~ ~r/^[0-9a-f]{64}$/
  end

  test "routed after_create failures stop the run before an agent starts" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-routed-after-create-#{System.unique_integer([:positive])}"
      )

    origin = Path.join(root, "origin")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(origin)
    on_exit(fn -> File.rm_rf(root) end)

    System.cmd("git", ["-C", origin, "init", "--quiet", "--initial-branch", "main"])
    System.cmd("git", ["-C", origin, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", origin, "config", "user.email", "test@example.com"])

    File.write!(
      Path.join(origin, "WORKFLOW.md"),
      """
      ---
      hooks:
        after_create: exit 17
      ---
      Test routed workflow.
      """
    )

    System.cmd("git", ["-C", origin, "add", "WORKFLOW.md"])
    System.cmd("git", ["-C", origin, "commit", "--quiet", "-m", "initial"])

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    File.write!(
      Application.fetch_env!(:symphony_elixir, :repo_config_path),
      """
      linear:
        team_id: UDPE
      repos:
        - id: test-repo
          label: repo:test-repo
          repo_url: #{origin}
          workflow_path: WORKFLOW.md
          base_branch: main
      """
    )

    issue = %Issue{
      id: "issue-after-create-failure",
      identifier: "UDPE-AFTER-CREATE",
      title: "Stop on fatal setup failure",
      state: "In Progress",
      labels: ["repo:test-repo"],
      comments: []
    }

    assert_raise RuntimeError, ~r/workspace_hook_failed.*after_create.*17/s, fn ->
      AgentRunner.run(issue)
    end
  end

  test "wait_for parks after one turn and emits a durable waiting lifecycle" do
    Application.put_env(:symphony_elixir, :waiting_backend_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :waiting_backend_recipient) end)

    issue = %Issue{
      id: "issue-agent-wait",
      identifier: "UDPE-WAIT",
      title: "Wait efficiently",
      state: "In Progress",
      labels: [],
      comments: []
    }

    assert :ok =
             AgentRunner.run_codex_turns_for_test(
               System.tmp_dir!(),
               issue,
               self(),
               [
                 agent_backend: {WaitingBackend, %{}},
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end,
                 issue_comments_fetcher: fn _issue_id ->
                   {:ok, %{comments: [], truncated: false}}
                 end,
                 wait_observer: fn _request ->
                   {:ok,
                    %{
                      "status" => "degraded",
                      "component" => "Actions",
                      "incident_statuses" => ["investigating"],
                      "recovery_signal" => "waiting"
                    }}
                 end,
                 max_turns: 5
               ],
               nil
             )

    assert_receive {:waiting_prompt, prompt}
    assert prompt =~ "call Symphony's `wait_for` tool once and end the turn"
    assert prompt =~ "Never call `wait_for` because of local CPU"
    assert prompt =~ "Symphony-owned handoff job"
    assert prompt =~ "only this current ticket's comments or state"
    assert prompt =~ "Do not park on a follow-up/tracking ticket"
    assert prompt =~ "permits validations from multiple agents to overlap"
    assert_receive {:waiting_tool_result, %{"success" => true}}

    assert_receive {:agent_lifecycle, "issue-agent-wait", :waiting, %{request: request}}
    assert request.condition["type"] == "github_actions_recovered"
    refute_receive {:waiting_prompt, _second_turn}, 100
  end

  test "synchronous handoff hooks publish a pending lifecycle around the tool call" do
    Application.put_env(:symphony_elixir, :handoff_tool_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :handoff_tool_recipient) end)

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-inline-handoff-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(workspace_root, "UDPE-INLINE-HANDOFF")
    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    issue = %Issue{
      id: "issue-inline-handoff",
      identifier: "UDPE-INLINE-HANDOFF",
      title: "Keep a synchronous handoff alive",
      state: "In Progress",
      labels: [],
      comments: []
    }

    issue_id = issue.id

    linear_client = fn
      query, %{"issueId" => issue_id, "stateName" => "In Review"}, []
      when issue_id == issue.id ->
        assert query =~ "SymphonyResolveTypedState"

        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-review"}]}}}
           }
         }}

      query, %{"issueId" => issue_id}, [] when issue_id == issue.id ->
        if String.contains?(query, "SymphonyResolveIssueTransition") do
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "state" => %{"name" => "In Progress"},
                 "team" => %{
                   "states" => %{
                     "nodes" => [%{"id" => "state-review", "name" => "In Review"}]
                   }
                 }
               }
             }
           }}
        else
          flunk("blocked handoff mutation should not reach Linear")
        end
    end

    assert :ok =
             AgentRunner.run_codex_turns_for_test(
               workspace,
               issue,
               self(),
               [
                 agent_backend: {HandoffToolBackend, %{}},
                 linear_client: linear_client,
                 per_repo_before_handoff: "sleep 0.2; exit 2",
                 per_repo_before_handoff_timeout_ms: 2_000,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 max_turns: 1
               ],
               nil
             )

    assert_receive {:agent_lifecycle, ^issue_id, :handoff_pending_gate, %{gate_job_id: gate_job_id, gate: %{status: :running}}}

    assert_receive {:agent_lifecycle, ^issue_id, :implementing, %{gate_job_id: ^gate_job_id, gate_outcome: :blocked}}

    assert_receive {:handoff_tool_result, %{"success" => false}}
    assert {:ok, nil} = Workspace.load_handoff_gate_state(workspace)

    assert {:ok, packet} = Workspace.load_resume_packet(workspace)
    assert packet["verification"]["gate_status"] == "blocked"
    assert packet["verification"]["gate_source"] == "symphony:before_handoff_gate"

    assert Enum.any?(packet["verification"]["check_summaries"], fn summary ->
             summary["name"] == "before_handoff" and summary["status"] == "failed" and
               summary["head_status"] == "unavailable_evidence_sha"
           end)
  end

  describe "soft-budget continuations" do
    test "includes changed Linear activity while reusing unchanged continuation sections" do
      recipient = self()
      Application.put_env(:symphony_elixir, :handoff_prompt_recipient_for_test, recipient)

      telemetry_handler_id =
        "agent-runner-activity-prompt-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        telemetry_handler_id,
        AgentRunner.prompt_built_telemetry_event(),
        fn _event, _measurements, metadata, _config ->
          send(recipient, {:activity_prompt_telemetry, metadata})
        end,
        nil
      )

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :handoff_prompt_recipient_for_test)
        :telemetry.detach(telemetry_handler_id)
      end)

      old_comment = %Comment{
        id: "old-comment",
        body: "Original activity.",
        author_name: "Owner",
        created_at: ~U[2026-08-02 09:00:00Z]
      }

      new_comment = %Comment{
        id: "new-comment",
        body: "New activity decision: preserve tenant isolation.",
        author_name: "Owner",
        created_at: ~U[2026-08-02 10:00:00Z]
      }

      issue = %Issue{
        id: "issue-activity-continuation",
        identifier: "UDPE-ACTIVITY",
        title: "Refresh current activity",
        description: "Use only the latest activity snapshot.",
        state: "In Progress",
        labels: [],
        comments: [old_comment],
        updated_at: ~U[2026-08-02 08:00:00Z]
      }

      fetcher = fn [_issue_id] ->
        count = Process.get(:activity_continuation_fetch_count, 0) + 1
        Process.put(:activity_continuation_fetch_count, count)

        refreshed =
          if count == 1 do
            %{issue | comments: [new_comment]}
          else
            %{issue | state: "Done", comments: [new_comment]}
          end

        {:ok, [refreshed]}
      end

      comments_fetcher = fn _issue_id ->
        {:ok, %{comments: [new_comment], truncated: false}}
      end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 System.tmp_dir!(),
                 issue,
                 nil,
                 [
                   agent_backend: {HandoffPromptBackend, %{}},
                   issue_state_fetcher: fetcher,
                   issue_comments_fetcher: comments_fetcher,
                   max_turns: 3
                 ],
                 nil
               )

      assert_receive {:handoff_prompt, initial_prompt, ^issue}
      assert initial_prompt =~ "Original activity."

      assert_receive {:handoff_prompt, continuation_prompt, refreshed_issue}
      assert refreshed_issue.comments == [new_comment]
      assert continuation_prompt =~ "New activity decision: preserve tenant isolation."
      assert continuation_prompt =~ "Current candidate metadata is unchanged"
      assert continuation_prompt =~ "Current Linear activity changed"
      refute continuation_prompt =~ "Original activity."

      assert_receive {:activity_prompt_telemetry, %{prompt_kind: "initial", prompt_sections: initial_sections}}

      assert Enum.map(initial_sections, & &1.id) == [
               "task.issue",
               "task.current_metadata",
               "task.activity",
               "repository.workflow",
               "symphony.test_worker_budget",
               "symphony.handoff_constraints",
               "continuation.status_resume_packet"
             ]

      assert_receive {:activity_prompt_telemetry,
                      %{
                        prompt_kind: "continuation",
                        prompt_sections: continuation_sections,
                        prompt_section_decisions: continuation_decisions
                      }}

      assert Enum.map(continuation_sections, & &1.id) == [
               "continuation.resume_capsule",
               "task.activity",
               "continuation.status_resume_packet"
             ]

      reused_ids =
        continuation_decisions
        |> Enum.filter(&(&1.decision == "reused"))
        |> Enum.map(& &1.section_id)

      assert Enum.sort(reused_ids) == [
               "repository.workflow",
               "symphony.handoff_constraints",
               "symphony.test_worker_budget",
               "task.current_metadata",
               "task.issue"
             ]
    end

    test "injects one bounded enforced transition on the next continuation" do
      Application.put_env(:symphony_elixir, :efficiency_recipient_for_test, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :efficiency_recipient_for_test) end)

      issue = %Issue{
        id: "issue-efficiency-runner",
        identifier: "UDPE-EFF",
        title: "Small direct edit",
        description: "Change one bounded helper.",
        state: "In Progress",
        labels: ["budget:simple"],
        blocked_by: [],
        children: []
      }

      fetcher = fn [_issue_id] ->
        count = Process.get(:efficiency_fetch_count, 0) + 1
        Process.put(:efficiency_fetch_count, count)
        state = if count == 1, do: "In Progress", else: "Done"
        {:ok, [%{issue | state: state}]}
      end

      workflow = %{
        config: %{
          "agent" => %{
            "efficiency" => %{
              "mode" => "enforce",
              "capsule_max_bytes" => 1_000,
              "profiles" => %{"simple" => %{"total_tokens" => 100}}
            }
          }
        }
      }

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 "/tmp",
                 issue,
                 self(),
                 [
                   agent_backend: {EfficiencyBackend, %{}},
                   issue_state_fetcher: fetcher,
                   per_repo_workflow: workflow,
                   max_turns: 2
                 ],
                 nil
               )

      assert_received {:efficiency_prompt, 1, first_prompt}
      assert_received {:efficiency_prompt, 2, second_prompt}
      refute first_prompt =~ "soft-budget resume capsule"
      assert second_prompt =~ "soft-budget resume capsule"
      assert second_prompt =~ "compact_parent_resume_capsule"
      assert length(String.split(second_prompt, "compact_parent_resume_capsule")) == 2

      assert_received {:worker_runtime_info, "issue-efficiency-runner", %{budget_profile: "simple", budget_mode: "enforce"}}
      assert_received {:worker_runtime_info, "issue-efficiency-runner", %{budget_transitions: transitions}}
      assert "soft:total_tokens" in transitions
    end

    test "coalesces high-volume usage without accumulating full events in the runner mailbox" do
      volume = 10_000
      Application.put_env(:symphony_elixir, :budget_stress_owner_for_test, self())
      Application.put_env(:symphony_elixir, :budget_stress_volume_for_test, volume)
      {:ok, recipient} = BudgetRuntimeRecipient.start_link(self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :budget_stress_owner_for_test)
        Application.delete_env(:symphony_elixir, :budget_stress_volume_for_test)
        if Process.alive?(recipient), do: GenServer.stop(recipient)
      end)

      issue = %Issue{
        id: "issue-efficiency-stress",
        identifier: "UDPE-EFF-STRESS",
        title: "Stress budget accounting",
        description: "Exercise a bounded collector with many cumulative updates.",
        state: "In Progress",
        labels: ["budget:simple"],
        blocked_by: [],
        children: []
      }

      workflow = %{
        config: %{
          "agent" => %{
            "efficiency" => %{
              "mode" => "enforce",
              "profiles" => %{
                "simple" => %{
                  "total_tokens" => 200,
                  "delegated_tokens" => 100,
                  "per_thread_tokens" => 100
                }
              }
            }
          }
        }
      }

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 "/tmp",
                 issue,
                 recipient,
                 [
                   agent_backend: {BudgetStressBackend, %{}},
                   issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                   per_repo_workflow: workflow,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received {:budget_stress_runner_queue_len, queue_len}
      assert queue_len < 10

      assert_received {:budget_runtime_info, "issue-efficiency-stress", %{budget_metrics: metrics, budget_transitions: transitions}}

      assert metrics.total_tokens == volume
      assert metrics.parent_tokens == div(volume, 2)
      assert metrics.delegated_tokens == div(volume, 2)
      assert metrics.thread_count == 2
      assert "soft:total_tokens" in transitions
      assert "soft:delegated_tokens" in transitions
      assert "soft:per_thread_tokens" in transitions
    end
  end

  describe "handoff prompt guidance" do
    test "routes review handoffs through the typed transition tool" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-handoff-prompt-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      Application.put_env(:symphony_elixir, :handoff_prompt_recipient_for_test, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :handoff_prompt_recipient_for_test)
        File.rm_rf(workspace)
      end)

      issue = %Issue{
        id: "issue-handoff-prompt",
        identifier: "UDPE-7062",
        title: "Use the host-side handoff gate",
        state: "In Progress",
        labels: []
      }

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {HandoffPromptBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 1,
                   per_repo_before_handoff: "scripts/hooks/before-handoff.sh"
                 ],
                 nil
               )

      assert_receive {:handoff_prompt, prompt, ^issue}
      assert prompt =~ "use Symphony's `linear_issue` tool"
      assert prompt =~ ~s(operation: "transition")
      assert prompt =~ "Do not construct a raw `linear_graphql` `issueUpdate` mutation"
      refute prompt =~ "LINEAR_API_KEY"
      refute prompt =~ "Symphony Linear access:"

      {task_prompt_position, _length} = :binary.match(prompt, "You are an agent for this repository.")
      {handoff_guidance_position, _length} = :binary.match(prompt, "Symphony handoff requirement:")
      assert handoff_guidance_position > task_prompt_position
    end
  end

  describe "injected issue activity" do
    test "fails the worker attempt instead of starting without required comments" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-issue-activity-failure-#{System.unique_integer([:positive])}")

      write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      on_exit(fn -> File.rm_rf(workspace_root) end)

      issue = %Issue{
        id: "issue-comments-unavailable",
        identifier: "UDPE-7011",
        title: "Do not start with incomplete input",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/issue_comments_fetch_failed.*linear_unavailable/, fn ->
        AgentRunner.run(issue, nil,
          issue_comments_fetcher: fn "issue-comments-unavailable" ->
            {:error, :linear_unavailable}
          end
        )
      end
    end

    test "places current Linear comments and blocked-resume guidance in the first turn" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-issue-activity-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      Application.put_env(:symphony_elixir, :handoff_prompt_recipient_for_test, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :handoff_prompt_recipient_for_test)
        File.rm_rf(workspace)
      end)

      issue = %Issue{
        id: "issue-resumed",
        identifier: "UDPE-7011",
        title: "Resume after a product decision",
        state: "In Progress",
        labels: ["needs-human-input"],
        comments: [
          %Comment{
            id: "comment-workpad",
            body: "## Codex Workpad\n\nBlocked on the product decision.",
            author_name: "UDPAgent",
            created_at: ~U[2026-07-29 09:00:00Z]
          },
          %Comment{
            id: "comment-decision",
            body: "Decision: use option B and continue.",
            author_name: "Product owner",
            created_at: ~U[2026-07-29 10:00:00Z]
          }
        ],
        comments_truncated: true
      }

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {HandoffPromptBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 1
                 ],
                 nil
               )

      assert_receive {:handoff_prompt, prompt, ^issue}
      assert prompt =~ "## Current Linear activity"
      assert prompt =~ "Decision: use option B and continue."
      assert prompt =~ "This issue is marked `needs-human-input`"
      assert prompt =~ "Remove the label only after consuming that response."
      assert prompt =~ "Earlier Linear comments were omitted"
      assert prompt =~ "## Host test-worker budget"
      assert prompt =~ "vitest --maxWorkers=2"
      assert prompt =~ "playwright test --workers=2"
    end

    test "treats a verified bot identity as authorized despite a stale auth blocker" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-bot-authorization-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      Application.put_env(:symphony_elixir, :handoff_prompt_recipient_for_test, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :handoff_prompt_recipient_for_test)
        File.rm_rf(workspace)
      end)

      issue = %Issue{
        id: "issue-bot-authorization",
        identifier: "UDPE-7016",
        title: "Resume with injected GitHub App auth",
        state: "In Progress",
        labels: ["needs-human-input", "UDPAgent"],
        comments: [
          %Comment{
            id: "comment-stale-auth-blocker",
            body: "## Codex Workpad\n\nBlocked until a human separately authorizes UDPAgent attribution, even if bot authentication is injected.",
            author_name: "UDPAgent"
          }
        ]
      }

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {HandoffPromptBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 1,
                   automation_opt_in_label: "udpagent"
                 ],
                 nil
               )

      assert_receive {:handoff_prompt, prompt, ^issue}
      assert prompt =~ "Symphony automation identity authorization:"
      assert prompt =~ "configured opt-in label `udpagent`"
      assert prompt =~ "that is both authentication and authorization"
      assert prompt =~ "Do not require a second human comment"
      assert prompt =~ "treat that claim as stale"
      assert prompt =~ "remove `needs-human-input`"

      {stale_blocker_position, _length} = :binary.match(prompt, "Blocked until a human separately authorizes")
      {authorization_position, _length} = :binary.match(prompt, "Symphony automation identity authorization:")
      assert authorization_position > stale_blocker_position
    end

    test "preserves injected comments when state refresh builds a continuation issue" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-issue-activity-refresh-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      Application.put_env(:symphony_elixir, :handoff_prompt_recipient_for_test, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :handoff_prompt_recipient_for_test)
        File.rm_rf(workspace)
      end)

      issue = %Issue{
        id: "issue-refresh",
        identifier: "UDPE-7011",
        title: "Preserve comment context",
        state: "In Progress",
        comments: [%Comment{id: "comment-1", body: "Decision: continue."}]
      }

      state_fetcher = fn
        [_issue_id] ->
          call_count = Process.get(:comment_refresh_call_count, 0)
          Process.put(:comment_refresh_call_count, call_count + 1)

          if call_count == 0 do
            {:ok, [%Issue{issue | comments: [], state: "In Progress"}]}
          else
            {:ok, [%Issue{issue | comments: [], state: "Done"}]}
          end
      end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {HandoffPromptBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 2
                 ],
                 nil
               )

      assert_receive {:handoff_prompt, first_prompt, ^issue}
      assert first_prompt =~ "Decision: continue."
      assert_receive {:handoff_prompt, second_prompt, second_issue}
      refute second_prompt =~ "## Current Linear activity"
      assert Enum.map(second_issue.comments, & &1.id) == ["comment-1"]
    end
  end

  describe "mark_blocked_on_giveup/2" do
    test "posts one comment, applies needs-human-input + idempotency label, transitions to Blocked on max_turns exhaustion" do
      issue = %Issue{id: "issue-123", identifier: "UDPE-100", labels: []}

      :ok =
        AgentRunner.mark_blocked_on_giveup(issue, %{
          reason: :max_turns_exhausted,
          turn_number: 20,
          max_turns: 20,
          workspace: "/tmp/symphony_workspaces/UDPE-100"
        })

      assert_received {:memory_tracker_comment, "issue-123", body}
      assert body =~ @blocked_marker
      assert body =~ "Symphony reached agent.max_turns (20/20)"
      assert body =~ "/tmp/symphony_workspaces/UDPE-100"

      assert_received {:memory_tracker_add_label, "issue-123", @needs_human_input_label}
      assert_received {:memory_tracker_add_label, "issue-123", @idempotency_label}
      assert_received {:memory_tracker_state_update, "issue-123", "Blocked"}
    end

    test "is idempotent: skips all writes when the issue already carries the routing-warned label" do
      issue = %Issue{
        id: "issue-456",
        identifier: "UDPE-101",
        labels: [@idempotency_label, "other-label"]
      }

      :ok =
        AgentRunner.mark_blocked_on_giveup(issue, %{
          reason: :max_turns_exhausted,
          turn_number: 20,
          max_turns: 20,
          workspace: "/tmp/x"
        })

      refute_received {:memory_tracker_comment, _id, _body}
      refute_received {:memory_tracker_add_label, _id, _label}
      refute_received {:memory_tracker_state_update, _id, _state}
    end

    test "continues with state transition even when needs-human-input label is missing in the workspace" do
      Application.put_env(:symphony_elixir, :memory_tracker_available_labels, [@idempotency_label])

      issue = %Issue{id: "issue-789", identifier: "UDPE-102", labels: []}

      :ok =
        AgentRunner.mark_blocked_on_giveup(issue, %{
          reason: :max_turns_exhausted,
          turn_number: 20,
          max_turns: 20,
          workspace: "/tmp/x"
        })

      assert_received {:memory_tracker_comment, "issue-789", _body}
      assert_received {:memory_tracker_add_label_missing, "issue-789", @needs_human_input_label}
      assert_received {:memory_tracker_add_label, "issue-789", @idempotency_label}
      assert_received {:memory_tracker_state_update, "issue-789", "Blocked"}
    end

    test "no-ops when called with a non-Issue map (defensive)" do
      :ok = AgentRunner.mark_blocked_on_giveup(%{}, %{reason: :max_turns_exhausted})

      refute_received {:memory_tracker_comment, _id, _body}
      refute_received {:memory_tracker_state_update, _id, _state}
    end
  end

  describe "deferred review handoff on abnormal turn completion" do
    test "runs the captured gate but withholds mutation when review is inconclusive" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-fix2-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      test_pid = self()

      issue = %Issue{
        id: "issue-abnormal",
        identifier: "UDPE-6566",
        title: "Open the PR",
        state: "In Progress",
        labels: []
      }

      # Records any unexpected Linear handoff mutation. A missing required PR
      # is now explicitly inconclusive and must never be treated as approval.
      linear_client = fn query, variables, _opts ->
        send(test_pid, {:handoff_mutation_applied, query, variables})
        {:ok, %{"data" => %{}}}
      end

      # No PR present -> the gate does not spawn a reviewer, but it withholds
      # the deferred mutation and preserves a non-approval outcome.
      no_pr = fn ["pr", "view" | _], _cwd -> {"no pull requests found", 1} end

      review_workflow = %{
        config: %{"review" => %{"max_iterations" => 3}},
        prompt: "Review {{ issue.identifier }}",
        prompt_template: "Review {{ issue.identifier }}"
      }

      request = %{
        query: "mutation { issueUpdate(input: {stateId: \"in-review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        review_workflow: review_workflow,
        review_opts: [
          pr_runner: no_pr,
          comment_fn: fn _id, _body -> :ok end,
          linear_client: linear_client
        ],
        linear_client: linear_client
      }

      Application.put_env(:symphony_elixir, :fix2_deferred_request, request)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :fix2_deferred_request)
        File.rm_rf(workspace)
      end)

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end

      assert {:error, {:turn_completed_abnormally, _}} =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {Fix2AbnormalBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 1
                 ],
                 nil
               )

      refute_received {:handoff_mutation_applied, _query, _variables}
    end
  end

  describe "deferred review lifecycle" do
    test "approves the exact head before starting and durably polling the handoff gate" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-review-before-gate-#{System.unique_integer([:positive])}"
        )

      workspace = Path.join(workspace_root, "UDPE-7431")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      {_, 0} = System.cmd("git", ["-C", workspace, "init", "--quiet"])
      File.write!(Path.join(workspace, "README.md"), "review before gate\n")
      {_, 0} = System.cmd("git", ["-C", workspace, "add", "README.md"])

      {_, 0} =
        System.cmd("git", [
          "-C",
          workspace,
          "-c",
          "user.name=Symphony Test",
          "-c",
          "user.email=symphony@example.com",
          "commit",
          "--quiet",
          "-m",
          "review before gate"
        ])

      {head_sha, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
      head_sha = String.trim(head_sha)
      test_pid = self()

      issue = %Issue{
        id: "issue-review-before-gate",
        identifier: "UDPE-7431",
        title: "Review before final validation",
        state: "In Progress",
        labels: []
      }

      review_workflow = %{
        config: %{"review" => %{"require_pr" => false}},
        prompt: "Review {{ issue.identifier }}",
        prompt_template: "Review {{ issue.identifier }}"
      }

      no_pr = fn ["pr", "view" | _], _cwd -> {"no pull requests found", 1} end

      review_runner = fn ctx ->
        send(test_pid, :review_started_before_gate)
        refute_received :handoff_gate_started
        write_review_verdict(ctx, %{"verdict" => "approve"})
        {:ok, %{}}
      end

      linear_client = fn query, variables, _opts ->
        send(test_pid, {:reviewed_handoff_applied, query, variables})
        {:ok, %{"data" => %{}}}
      end

      review_opts = [
        pr_runner: no_pr,
        session_runner: review_runner,
        comment_fn: fn _id, _body -> :ok end,
        linear_client: linear_client
      ]

      handoff_request = %{
        query: "mutation { issueUpdate(input: {stateId: \"in-review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        target_state: "In Review",
        before_handoff_command: nil,
        before_handoff_timeout_ms: nil,
        before_handoff_stale_ms: nil,
        review_workflow: review_workflow,
        review_opts: review_opts,
        linear_client: linear_client
      }

      review_request = %{
        query: handoff_request.query,
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        review_workflow: review_workflow,
        review_opts: review_opts,
        linear_client: linear_client,
        handoff_after_review: handoff_request
      }

      Application.put_env(:symphony_elixir, :deferred_requests_for_test, [review_request])

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :deferred_requests_for_test)
        File.rm_rf(workspace_root)
      end)

      starter = fn ^workspace, ^issue, nil, "In Review", start_opts ->
        assert start_opts[:async] == true
        send(test_pid, :handoff_gate_started)
        {:pending, async_gate(:pending)}
      end

      poller = fn ^workspace, ^issue, nil, "In Review", "job-7157", _poll_opts ->
        assert {:ok,
                %{
                  "phase" => "polling",
                  "reviewApproval" => %{
                    "kind" => "workspace",
                    "issueId" => "issue-review-before-gate",
                    "reviewedSha" => ^head_sha
                  }
                }} = Workspace.load_handoff_gate_state(workspace)

        send(test_pid, :handoff_gate_polled)
        {:passed, async_gate(:passed)}
      end

      state_fetcher = fn ["issue-review-before-gate"] -> {:ok, [issue]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {DeferredBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   handoff_gate_starter: starter,
                   handoff_gate_poller: poller,
                   handoff_gate_sleep: fn _milliseconds -> :ok end,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received :review_started_before_gate
      assert_received :handoff_gate_started
      assert_received :handoff_gate_polled
      assert_received {:reviewed_handoff_applied, query, %{}}
      assert query =~ "issueUpdate"
      refute_received :review_started_before_gate
      assert {:ok, nil} = Workspace.load_handoff_gate_state(workspace)

      assert {:ok, packet} = Workspace.load_resume_packet(workspace)
      assert packet["verification"]["source"] == "symphony:combined_gate_review"
      assert packet["verification"]["gate_source"] == "symphony:before_handoff_gate"
      assert packet["verification"]["review_source"] == "symphony:automated_review"
      assert is_binary(packet["verification"]["gate_captured_at"])
      assert is_binary(packet["verification"]["review_captured_at"])
    end

    test "ends the worker attempt when review infrastructure is unavailable" do
      workspace =
        Path.join(
          System.tmp_dir!(),
          "symphony-review-infrastructure-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace)
      {_, 0} = System.cmd("git", ["-C", workspace, "init", "--quiet"])
      File.write!(Path.join(workspace, "README.md"), "review target\n")
      {_, 0} = System.cmd("git", ["-C", workspace, "add", "README.md"])

      {_, 0} =
        System.cmd("git", [
          "-C",
          workspace,
          "-c",
          "user.name=Symphony Test",
          "-c",
          "user.email=symphony@example.com",
          "commit",
          "--quiet",
          "-m",
          "review target"
        ])

      test_pid = self()

      issue = %Issue{
        id: "issue-review-infrastructure",
        identifier: "UDPE-7203",
        title: "Back off after review infrastructure failure",
        state: "In Progress",
        labels: []
      }

      linear_client = fn query, variables, _opts ->
        send(test_pid, {:unexpected_review_handoff, query, variables})
        {:ok, %{"data" => %{}}}
      end

      no_pr = fn ["pr", "view" | _], _cwd -> {"no pull requests found", 1} end

      request = %{
        query: "mutation { issueUpdate(input: {stateId: \"in-review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        review_workflow: %{
          config: %{"review" => %{"require_pr" => false}},
          prompt: "Review {{ issue.identifier }}",
          prompt_template: "Review {{ issue.identifier }}"
        },
        review_opts: [
          pr_runner: no_pr,
          review_packet_builder: fn _workspace, _issue, _pr, _reviewed_sha, _prior_outcome, _settings, _opts ->
            send(test_pid, :review_packet_failed)
            {:error, :packet_builder_failed}
          end,
          comment_fn: fn _id, _body -> :ok end,
          linear_client: linear_client
        ],
        linear_client: linear_client
      }

      Application.put_env(:symphony_elixir, :deferred_requests_for_test, [request])

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :deferred_requests_for_test)
        File.rm_rf(workspace)
      end)

      state_fetcher = fn [_issue_id] -> {:ok, [issue]} end

      assert {:error,
              {:review_gate_infrastructure,
               %{
                 review: %{
                   outcome: "infrastructure_unavailable",
                   failure_reason: failure_reason
                 }
               }}} =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {DeferredBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 5
                 ],
                 nil
               )

      assert failure_reason =~ "review_packet_unavailable"
      assert_received :review_packet_failed
      refute_received {:unexpected_review_handoff, _, _}
    end

    test "coalesces repeated handoff requests into one review and one mutation" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-coalesced-review-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      {_, 0} = System.cmd("git", ["-C", workspace, "init", "--quiet"])
      File.write!(Path.join(workspace, "README.md"), "review target\n")
      {_, 0} = System.cmd("git", ["-C", workspace, "add", "README.md"])

      {_, 0} =
        System.cmd("git", [
          "-C",
          workspace,
          "-c",
          "user.name=Symphony Test",
          "-c",
          "user.email=symphony@example.com",
          "commit",
          "--quiet",
          "-m",
          "test review target"
        ])

      test_pid = self()
      {head_sha, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
      head_sha = String.trim(head_sha)

      issue = %Issue{
        id: "issue-coalesced",
        identifier: "UDPE-6460",
        title: "Coalesce review",
        state: "In Progress",
        labels: []
      }

      linear_client = fn query, variables, _opts ->
        send(test_pid, {:handoff_mutation_applied, query, variables})
        {:ok, %{"data" => %{}}}
      end

      review_runner = fn ctx ->
        send(test_pid, {:review_session_started, ctx.packet.validation_attestations})
        write_review_verdict(ctx, %{"verdict" => "approve"})
        {:ok, %{}}
      end

      no_pr = fn ["pr", "view" | _], _cwd -> {"no pull requests found", 1} end

      review_workflow = %{
        config: %{"review" => %{"require_pr" => false}},
        prompt: "Review {{ issue.identifier }}",
        prompt_template: "Review {{ issue.identifier }}"
      }

      request = %{
        query: "mutation { issueUpdate(input: {stateId: \"in-review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        gate: %{
          async_gate(:passed)
          | identity:
              Map.merge(async_gate(:passed).identity, %{
                "headSha" => head_sha,
                "mutablePrStateHash" => "mutable-state-7157",
                "prNumber" => "18"
              }),
            checks: [%{"id" => "check-evidence-fresh", "status" => "passed"}],
            result_artifact: ".artifacts/before-handoff/result.json"
        },
        review_workflow: review_workflow,
        review_opts: [
          pr_runner: no_pr,
          session_runner: review_runner,
          comment_fn: fn _id, _body -> :ok end,
          linear_client: linear_client
        ],
        linear_client: linear_client
      }

      Application.put_env(:symphony_elixir, :deferred_requests_for_test, [request, request])

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :deferred_requests_for_test)
        File.rm_rf(workspace)
      end)

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {DeferredBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received {:review_session_started, attestations}

      assert Enum.any?(attestations, fn attestation ->
               attestation.command == "before_handoff/check-evidence-fresh" and
                 attestation.head_sha == head_sha and
                 attestation.exact_hash == "exact-7157" and
                 attestation.mutable_pr_state_hash == "mutable-state-7157"
             end)

      refute_received {:review_session_started, _attestations}
      assert_received {:handoff_mutation_applied, query, %{}}
      assert query =~ "issueUpdate"
      refute_received {:handoff_mutation_applied, _, _}
    end

    test "withholds a reviewed handoff when the pull request head changes" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-head-change-review-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      test_pid = self()

      issue = %Issue{
        id: "issue-head-change",
        identifier: "UDPE-6460",
        title: "Revalidate review head",
        state: "In Progress",
        labels: []
      }

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      pr_runner = fn
        ["pr", "view" | _], _cwd ->
          call = Agent.get_and_update(counter, fn count -> {count, count + 1} end)
          head = if call == 0, do: "head-before-review", else: "head-after-review"

          {Jason.encode!(%{
             "id" => "PR_head_change",
             "number" => 64,
             "body" => "Body.",
             "headRefOid" => head
           }), 0}

        ["api", "graphql" | _], _cwd ->
          {"", 0}
      end

      review_runner = fn ctx ->
        write_review_verdict(ctx, %{"verdict" => "approve"})
        {:ok, %{}}
      end

      linear_client = fn query, variables, _opts ->
        send(test_pid, {:unexpected_handoff_mutation, query, variables})
        {:ok, %{"data" => %{}}}
      end

      review_workflow = %{
        config: %{"review" => %{}},
        prompt: "Review {{ issue.identifier }}",
        prompt_template: "Review {{ issue.identifier }}"
      }

      request = %{
        query: "mutation { issueUpdate(input: {stateId: \"in-review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        review_workflow: review_workflow,
        review_opts: [
          pr_runner: pr_runner,
          session_runner: review_runner,
          comment_fn: fn _id, _body -> :ok end,
          linear_client: linear_client
        ],
        linear_client: linear_client
      }

      Application.put_env(:symphony_elixir, :deferred_requests_for_test, [request])

      on_exit(fn ->
        if Process.alive?(counter), do: Agent.stop(counter)
        Application.delete_env(:symphony_elixir, :deferred_requests_for_test)
        File.rm_rf(workspace)
      end)

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {DeferredBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 1
                 ],
                 nil
               )

      refute_received {:unexpected_handoff_mutation, _, _}
      assert Agent.get(counter, & &1) == 2
    end

    test "enters pending review before blocking PR target resolution" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-review-preflight-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      test_pid = self()
      {:ok, recipient} = LifecycleRecipient.start_link(test_pid)

      issue = %Issue{
        id: "issue-preflight",
        identifier: "UDPE-6460",
        title: "Track review preflight",
        state: "In Progress",
        labels: []
      }

      pr_runner = fn
        ["pr", "view" | _], _cwd ->
          unless Process.get(:preflight_released) do
            send(test_pid, {:review_preflight_waiting, self()})

            receive do
              :release_review_preflight -> Process.put(:preflight_released, true)
            end
          end

          {Jason.encode!(%{
             "id" => "PR_preflight",
             "number" => 65,
             "body" => "Body.",
             "headRefOid" => "head-preflight"
           }), 0}

        ["api", "graphql" | _], _cwd ->
          {"", 0}
      end

      review_runner = fn ctx ->
        write_review_verdict(ctx, %{"verdict" => "approve"})
        {:ok, %{}}
      end

      linear_client = fn _query, _variables, _opts -> {:ok, %{"data" => %{}}} end

      review_workflow = %{
        config: %{"review" => %{}},
        prompt: "Review {{ issue.identifier }}",
        prompt_template: "Review {{ issue.identifier }}"
      }

      request = %{
        query: "mutation { issueUpdate(input: {stateId: \"in-review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        review_workflow: review_workflow,
        review_opts: [
          pr_runner: pr_runner,
          session_runner: review_runner,
          comment_fn: fn _id, _body -> :ok end,
          linear_client: linear_client
        ],
        linear_client: linear_client
      }

      Application.put_env(:symphony_elixir, :deferred_requests_for_test, [request])

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :deferred_requests_for_test)
        File.rm_rf(workspace)
      end)

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      task =
        Task.async(fn ->
          AgentRunner.run_codex_turns_for_test(
            workspace,
            issue,
            recipient,
            [
              agent_backend: {DeferredBackend, %{}},
              issue_state_fetcher: state_fetcher,
              max_turns: 1
            ],
            nil
          )
        end)

      assert_receive {:lifecycle_call, {:agent_lifecycle, "issue-preflight", :handoff_pending_review, %{review_key: {:resolving_review_target, "issue-preflight"}}}},
                     1_000

      assert_receive {:review_preflight_waiting, runner_pid}, 1_000
      send(runner_pid, :release_review_preflight)

      assert :ok = Task.await(task, 2_000)

      assert_receive {:lifecycle_call, {:agent_lifecycle, "issue-preflight", :handoff_pending_review, %{review_key: {:pull_request, "issue-preflight", "PR_preflight", "head-preflight"}}}},
                     1_000

      assert_receive {:lifecycle_call,
                      {:agent_lifecycle, "issue-preflight", :implementing,
                       %{
                         review_outcome: :approved,
                         review_state: %{
                           outcome: "approved",
                           reviewed_sha: "head-preflight",
                           iteration: 1,
                           severity_counts: %{}
                         }
                       }}},
                     1_000
    end

    test "live orchestrator does not redispatch while the shared runner reviews" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        codex_stall_timeout_ms: 1_000
      )

      workspace =
        Path.join(System.tmp_dir!(), "symphony-live-review-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      {_, 0} = System.cmd("git", ["-C", workspace, "init", "--quiet"])
      File.write!(Path.join(workspace, "README.md"), "live review target\n")
      {_, 0} = System.cmd("git", ["-C", workspace, "add", "README.md"])

      {_, 0} =
        System.cmd("git", [
          "-C",
          workspace,
          "-c",
          "user.name=Symphony Test",
          "-c",
          "user.email=symphony@example.com",
          "commit",
          "--quiet",
          "-m",
          "live review target"
        ])

      test_pid = self()

      issue = %Issue{
        id: "issue-live-review",
        identifier: "UDPE-6460",
        title: "Pause during review",
        state: "In Progress",
        labels: []
      }

      review_runner = fn ctx ->
        review_event_at = DateTime.utc_now()

        ctx.on_message.(%{
          event: :notification,
          timestamp: review_event_at,
          payload: %{"method" => "review/heartbeat"}
        })

        send(test_pid, {:review_runner_waiting, self(), review_event_at})

        receive do
          :finish_review -> :ok
        end

        write_review_verdict(ctx, %{"verdict" => "approve"})
        {:ok, %{}}
      end

      no_pr = fn ["pr", "view" | _], _cwd -> {"no pull requests found", 1} end
      linear_client = fn _query, _variables, _opts -> {:ok, %{"data" => %{}}} end

      review_workflow = %{
        config: %{"review" => %{"require_pr" => false}},
        prompt: "Review {{ issue.identifier }}",
        prompt_template: "Review {{ issue.identifier }}"
      }

      request = %{
        query: "mutation { issueUpdate(input: {stateId: \"in-review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        review_workflow: review_workflow,
        review_opts: [
          pr_runner: no_pr,
          session_runner: review_runner,
          comment_fn: fn _id, _body -> :ok end,
          linear_client: linear_client
        ],
        linear_client: linear_client
      }

      Application.put_env(:symphony_elixir, :blocking_deferred_request_for_test, request)
      Application.put_env(:symphony_elixir, :blocking_deferred_recipient_for_test, test_pid)
      # Keep the orchestrator's immediate startup poll from racing this test's
      # deliberately injected running entry.
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :LiveReviewOrchestrator)
      {:ok, orchestrator} = Orchestrator.start_link(name: orchestrator_name)
      Process.sleep(50)

      on_exit(fn ->
        if Process.alive?(orchestrator), do: Process.exit(orchestrator, :normal)
        Application.delete_env(:symphony_elixir, :blocking_deferred_request_for_test)
        Application.delete_env(:symphony_elixir, :blocking_deferred_recipient_for_test)
        File.rm_rf(workspace)
      end)

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      task =
        Task.async(fn ->
          AgentRunner.run_codex_turns_for_test(
            workspace,
            issue,
            orchestrator,
            [
              agent_backend: {BlockingDeferredBackend, %{}},
              issue_state_fetcher: state_fetcher,
              max_turns: 1
            ],
            nil
          )
        end)

      assert_receive {:implementor_turn_ready, worker_pid}, 1_000
      stale_at = DateTime.add(DateTime.utc_now(), -5, :second)
      initial_state = :sys.get_state(orchestrator)

      running_entry = %{
        pid: worker_pid,
        ref: make_ref(),
        identifier: issue.identifier,
        issue: issue,
        session_id: "live-review-session",
        last_codex_timestamp: stale_at,
        lifecycle_state: :implementing,
        lifecycle_started_at: stale_at,
        started_at: stale_at
      }

      :sys.replace_state(orchestrator, fn _ ->
        initial_state
        |> Map.put(:running, %{issue.id => running_entry})
        |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue.id))
      end)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      send(worker_pid, :finish_implementor_turn)
      assert_receive {:review_runner_waiting, ^worker_pid, review_event_at}, 1_000

      send(orchestrator, :tick)
      Process.sleep(100)
      state = :sys.get_state(orchestrator)

      assert Process.alive?(worker_pid)
      assert state.running[issue.id].lifecycle_state == :handoff_pending_review
      assert state.running[issue.id].last_codex_timestamp == stale_at
      assert state.running[issue.id].handoff_review_last_event_at == review_event_at
      assert MapSet.member?(state.claimed, issue.id)
      refute Map.has_key?(state.retry_attempts, issue.id)

      send(worker_pid, :finish_review)
      assert :ok = Task.await(task, 2_000)
    end
  end

  describe "asynchronous handoff gate recovery" do
    test "retains a blocked recovered-start gate breakdown without claiming exact-head evidence" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-gate-start-blocked-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "UDPE-7502-BLOCKED")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-gate-start-blocked",
        identifier: "UDPE-7502-BLOCKED",
        title: "Retain blocked gate evidence",
        state: "In Progress",
        labels: []
      }

      query =
        "mutation Move { issueUpdate(id: \"issue-gate-start-blocked\", input: {stateId: \"review\"}) { success } }"

      assert :ok =
               Workspace.persist_handoff_gate_state(workspace, %{
                 "phase" => "starting",
                 "query" => query,
                 "variables" => %{},
                 "targetState" => "In Review"
               })

      Application.put_env(:symphony_elixir, :handoff_prompt_recipient_for_test, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :handoff_prompt_recipient_for_test)
        File.rm_rf(workspace_root)
      end)

      starter = fn ^workspace, ^issue, nil, "In Review", _start_opts ->
        {:blocked, "Fix the recovered gate.",
         [
           %{name: "make all", status: "failed", passed: false, detail: "failed"}
         ]}
      end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {HandoffPromptBackend, %{}},
                   issue_context_file: Workspace.issue_context_path(workspace),
                   issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end,
                   handoff_gate_starter: starter,
                   repository_manifest: %{head_sha: String.duplicate("a", 40), dirty: false, errors: []},
                   max_turns: 1
                 ],
                 nil
               )

      assert_receive {:handoff_prompt, prompt, ^issue}
      assert prompt =~ "Fix the recovered gate."

      assert {:ok, packet} = Workspace.load_resume_packet(workspace)
      assert packet["verification"]["gate_status"] == "blocked"

      assert [%{"name" => "make all", "status" => "failed", "head_status" => "unavailable_evidence_sha"}] =
               Enum.map(
                 packet["verification"]["check_summaries"],
                 &Map.take(&1, ~w(name status head_status))
               )
    end

    test "retries a durable gate start without opening another model session" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-gate-start-recovery-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "UDPE-7370")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-gate-start-recovery",
        identifier: "UDPE-7370",
        title: "Recover a gate start timeout",
        state: "In Progress",
        labels: []
      }

      query =
        "mutation Move { issueUpdate(id: \"issue-gate-start-recovery\", input: {stateId: \"review\"}) { success } }"

      assert :ok =
               Workspace.persist_handoff_gate_state(workspace, %{
                 "phase" => "starting",
                 "query" => query,
                 "variables" => %{},
                 "targetState" => "In Review"
               })

      Application.put_env(:symphony_elixir, :turn_count_recipient_for_test, self())
      {:ok, starts} = Agent.start_link(fn -> 0 end)
      test_pid = self()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :turn_count_recipient_for_test)
        if Process.alive?(starts), do: Agent.stop(starts)
        File.rm_rf(workspace_root)
      end)

      starter = fn ^workspace, ^issue, nil, "In Review", start_opts ->
        assert start_opts[:async] == true
        attempt = Agent.get_and_update(starts, fn count -> {count, count + 1} end)
        send(test_pid, {:durable_gate_start_attempt, attempt + 1})

        if attempt == 0 do
          {:infrastructure_error, "gate start timed out", %{status: :infrastructure_error}}
        else
          {:pending, async_gate(:pending)}
        end
      end

      poller = fn ^workspace, ^issue, nil, "In Review", "job-7157", _poll_opts ->
        send(test_pid, :recovered_gate_polled)
        {:passed, async_gate(:passed)}
      end

      linear_client = fn ^query, %{}, [] ->
        send(test_pid, :recovered_gate_handoff_applied)
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end

      state_fetcher = fn ["issue-gate-start-recovery"] -> {:ok, [issue]} end

      opts = [
        agent_backend: {TurnCountingBackend, %{}},
        issue_context_file: Workspace.issue_context_path(workspace),
        issue_state_fetcher: state_fetcher,
        handoff_gate_starter: starter,
        handoff_gate_poller: poller,
        handoff_gate_sleep: fn _milliseconds -> :ok end,
        linear_client: linear_client,
        max_turns: 1
      ]

      assert {:error, {:handoff_gate_infrastructure, %{message: "gate start timed out", gate: %{status: :infrastructure_error}}}} =
               AgentRunner.run_codex_turns_for_test(workspace, issue, nil, opts, nil)

      assert_received {:durable_gate_start_attempt, 1}
      refute_received :turn_ran

      assert {:ok, %{"phase" => "starting"}} = Workspace.load_handoff_gate_state(workspace)

      assert :ok = AgentRunner.run_codex_turns_for_test(workspace, issue, nil, opts, nil)

      assert_received {:durable_gate_start_attempt, 2}
      assert_received :recovered_gate_polled
      assert_received :recovered_gate_handoff_applied
      refute_received :turn_ran
      assert {:ok, nil} = Workspace.load_handoff_gate_state(workspace)
    end

    test "revalidates handoff runtime drift before retrying a durable gate start" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-gate-start-drift-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "UDPE-7370")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-gate-start-drift",
        identifier: "UDPE-7370",
        title: "Refresh a stale handoff runtime",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               Workspace.persist_handoff_gate_state(workspace, %{
                 "phase" => "starting",
                 "query" => "mutation Move { issueUpdate(id: \"issue-gate-start-drift\", input: {stateId: \"review\"}) { success } }",
                 "variables" => %{},
                 "targetState" => "In Review"
               })

      Application.put_env(:symphony_elixir, :handoff_prompt_recipient_for_test, self())
      test_pid = self()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :handoff_prompt_recipient_for_test)
        File.rm_rf(workspace_root)
      end)

      starter = fn _workspace, _issue, _worker_host, _target_state, _start_opts ->
        send(test_pid, :stale_handoff_started)
        :ok
      end

      git_runner = fn
        ["rev-parse", "HEAD"], ^workspace ->
          {"candidate-head\n", 0}

        ["fetch", "--quiet", "origin", "develop"], ^workspace ->
          {"", 0}

        ["rev-parse", "refs/remotes/origin/develop"], ^workspace ->
          {"current-base\n", 0}

        ["merge-base", "candidate-head", "current-base"], ^workspace ->
          {"candidate-base\n", 0}

        ["diff", "--name-only", "candidate-base..HEAD"], ^workspace ->
          {"app/widget.tsx\n", 0}

        ["diff", "--name-only", "HEAD"], ^workspace ->
          {"", 0}

        ["diff", "--name-only", "--cached"], ^workspace ->
          {"", 0}

        ["ls-files", "--others", "--exclude-standard"], ^workspace ->
          {"", 0}

        ["diff", "--name-only", "candidate-base..current-base"], ^workspace ->
          {"scripts/hooks/before-handoff.sh\n", 0}

        ["status", "--porcelain", "--untracked-files=normal"], ^workspace ->
          {"", 0}
      end

      state_fetcher = fn ["issue-gate-start-drift"] -> {:ok, [issue]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {HandoffPromptBackend, %{}},
                   issue_context_file: Workspace.issue_context_path(workspace),
                   issue_state_fetcher: state_fetcher,
                   handoff_gate_starter: starter,
                   base_drift_ref: "develop",
                   base_drift_git_runner: git_runner,
                   per_repo_before_handoff: "scripts/hooks/before-handoff.sh",
                   max_turns: 1
                 ],
                 nil
               )

      assert_received {:handoff_prompt, prompt, ^issue}
      assert prompt =~ "paths required by the configured handoff runtime"
      assert prompt =~ "scripts/hooks/before-handoff.sh"
      refute_received :stale_handoff_started
      assert {:ok, nil} = Workspace.load_handoff_gate_state(workspace)
    end

    test "reattaches to a reviewed durable job and applies an exact-candidate pass without a model turn" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-gate-recovery-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "UDPE-7157")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      {_, 0} = System.cmd("git", ["-C", workspace, "init", "--quiet"])
      File.write!(Path.join(workspace, "README.md"), "reviewed durable handoff\n")
      {_, 0} = System.cmd("git", ["-C", workspace, "add", "README.md"])

      {_, 0} =
        System.cmd("git", [
          "-C",
          workspace,
          "-c",
          "user.name=Symphony Test",
          "-c",
          "user.email=symphony@example.com",
          "commit",
          "--quiet",
          "-m",
          "reviewed durable handoff"
        ])

      {reviewed_sha, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
      reviewed_sha = String.trim(reviewed_sha)

      issue = %Issue{
        id: "issue-gate-recovery",
        identifier: "UDPE-7157",
        title: "Recover pending gate",
        state: "In Progress",
        labels: []
      }

      pending_gate = async_gate(:pending)

      assert :ok =
               Workspace.persist_handoff_gate_state(workspace, %{
                 "query" => "mutation Move { issueUpdate(id: \"issue-gate-recovery\", input: {stateId: \"review\"}) { success } }",
                 "variables" => %{},
                 "targetState" => "In Review",
                 "reviewApproval" => %{
                   "kind" => "workspace",
                   "issueId" => "issue-gate-recovery",
                   "reviewedSha" => reviewed_sha
                 },
                 "gate" => %{
                   "jobId" => pending_gate.job_id,
                   "status" => "pending",
                   "candidateHash" => pending_gate.candidate_hash,
                   "exactHash" => pending_gate.exact_hash,
                   "identity" => pending_gate.identity,
                   "heartbeatAt" => pending_gate.heartbeat_at,
                   "heartbeatAgeMs" => pending_gate.heartbeat_age_ms,
                   "nextPollMs" => pending_gate.next_poll_ms,
                   "progress" => pending_gate.progress,
                   "startedAt" => pending_gate.started_at
                 }
               })

      Application.put_env(:symphony_elixir, :turn_count_recipient_for_test, self())
      test_pid = self()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :turn_count_recipient_for_test)
        File.rm_rf(workspace_root)
      end)

      poller = fn ^workspace, ^issue, nil, "In Review", "job-7157", poll_opts ->
        assert poll_opts[:expected_candidate_hash] == "candidate-7157"
        send(test_pid, :durable_gate_polled)
        {:passed, async_gate(:passed)}
      end

      linear_client = fn query, %{}, [] ->
        send(test_pid, {:recovered_handoff_applied, query})
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end

      state_fetcher = fn ["issue-gate-recovery"] -> {:ok, [issue]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {TurnCountingBackend, %{}},
                   issue_context_file: Workspace.issue_context_path(workspace),
                   issue_state_fetcher: state_fetcher,
                   handoff_gate_poller: poller,
                   linear_client: linear_client,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received :durable_gate_polled
      assert_received {:recovered_handoff_applied, query}
      assert query =~ "issueUpdate"
      refute_received :turn_ran
      assert {:ok, nil} = Workspace.load_handoff_gate_state(workspace)
    end

    test "retries a transient issue refresh without clearing the durable gate or opening a model turn" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-gate-refresh-retry-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "UDPE-7446")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-gate-refresh-retry",
        identifier: "UDPE-7446",
        title: "Preserve a gate across tracker timeouts",
        state: "In Progress",
        labels: []
      }

      pending_gate = async_gate(:pending)
      query = "mutation Move { issueUpdate(id: \"issue-gate-refresh-retry\", input: {stateId: \"review\"}) { success } }"

      assert :ok =
               Workspace.persist_handoff_gate_state(workspace, %{
                 "query" => query,
                 "variables" => %{},
                 "targetState" => "In Review",
                 "gate" => %{
                   "jobId" => pending_gate.job_id,
                   "status" => "pending",
                   "candidateHash" => pending_gate.candidate_hash,
                   "exactHash" => pending_gate.exact_hash,
                   "identity" => pending_gate.identity,
                   "heartbeatAt" => pending_gate.heartbeat_at,
                   "heartbeatAgeMs" => pending_gate.heartbeat_age_ms,
                   "nextPollMs" => pending_gate.next_poll_ms,
                   "progress" => pending_gate.progress,
                   "startedAt" => pending_gate.started_at
                 }
               })

      Application.put_env(:symphony_elixir, :turn_count_recipient_for_test, self())
      {:ok, state_reads} = Agent.start_link(fn -> 0 end)
      test_pid = self()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :turn_count_recipient_for_test)
        if Process.alive?(state_reads), do: Agent.stop(state_reads)
        File.rm_rf(workspace_root)
      end)

      state_fetcher = fn ["issue-gate-refresh-retry"] ->
        case Agent.get_and_update(state_reads, fn count -> {count, count + 1} end) do
          0 -> {:error, {:linear_api_request, %Req.TransportError{reason: :timeout}}}
          1 -> {:ok, [issue]}
        end
      end

      poller = fn ^workspace, ^issue, nil, "In Review", "job-7157", _poll_opts ->
        send(test_pid, :durable_gate_polled_after_refresh)
        {:passed, async_gate(:passed)}
      end

      linear_client = fn ^query, %{}, [] ->
        send(test_pid, :durable_gate_handoff_applied_after_refresh)
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 self(),
                 [
                   agent_backend: {TurnCountingBackend, %{}},
                   issue_context_file: Workspace.issue_context_path(workspace),
                   issue_state_fetcher: state_fetcher,
                   handoff_gate_poller: poller,
                   handoff_issue_refresh_sleep: fn delay_ms ->
                     send(test_pid, {
                       :issue_refresh_retry_sleep,
                       delay_ms,
                       Workspace.load_handoff_gate_state(workspace)
                     })
                   end,
                   linear_client: linear_client,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received {:issue_refresh_retry_sleep, delay_ms, {:ok, %{"gate" => %{"jobId" => "job-7157"}}}}
      assert delay_ms >= 1_000 and delay_ms <= 1_200
      assert_received :durable_gate_polled_after_refresh
      assert_received :durable_gate_handoff_applied_after_refresh
      refute_received :turn_ran
      assert {:ok, nil} = Workspace.load_handoff_gate_state(workspace)
    end

    test "adopts a live replacement gate and finishes its lifecycle without a model turn" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-gate-replacement-#{System.unique_integer([:positive])}"
        )

      workspace = Path.join(workspace_root, "UDPE-7372")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-gate-replacement",
        identifier: "UDPE-7372",
        title: "Follow a replacement gate",
        state: "In Progress",
        labels: []
      }

      original_gate = async_gate(:pending)
      replacement_gate = %{original_gate | job_id: "job-86814", candidate_hash: "candidate-86814"}
      {:ok, original_polls} = Agent.start_link(fn -> 0 end)

      assert :ok =
               Workspace.persist_handoff_gate_state(workspace, %{
                 "query" => "mutation Move { issueUpdate(id: \"issue-gate-replacement\", input: {stateId: \"review\"}) { success } }",
                 "variables" => %{},
                 "targetState" => "In Review",
                 "gate" => %{
                   "jobId" => original_gate.job_id,
                   "status" => "pending",
                   "candidateHash" => original_gate.candidate_hash,
                   "exactHash" => original_gate.exact_hash,
                   "identity" => original_gate.identity,
                   "heartbeatAt" => original_gate.heartbeat_at,
                   "heartbeatAgeMs" => original_gate.heartbeat_age_ms,
                   "nextPollMs" => original_gate.next_poll_ms,
                   "progress" => original_gate.progress,
                   "startedAt" => original_gate.started_at
                 }
               })

      Application.put_env(:symphony_elixir, :turn_count_recipient_for_test, self())
      test_pid = self()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :turn_count_recipient_for_test)
        if Process.alive?(original_polls), do: Agent.stop(original_polls)
        File.rm_rf(workspace_root)
      end)

      poller = fn
        ^workspace, ^issue, nil, "In Review", "job-7157", _poll_opts ->
          case Agent.get_and_update(original_polls, fn count -> {count, count + 1} end) do
            0 ->
              send(test_pid, :unchanged_gate_polled)
              {:pending, %{original_gate | heartbeat_age_ms: 20}}

            1 ->
              send(test_pid, :replacement_gate_adopted)
              {:pending, replacement_gate}
          end

        ^workspace, ^issue, nil, "In Review", "job-86814", _poll_opts ->
          send(test_pid, :replacement_gate_polled)
          {:passed, %{replacement_gate | status: :passed}}
      end

      linear_client = fn _query, %{}, [] ->
        send(test_pid, :replacement_gate_handoff_applied)
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 self(),
                 [
                   agent_backend: {TurnCountingBackend, %{}},
                   issue_context_file: Workspace.issue_context_path(workspace),
                   issue_state_fetcher: fn ["issue-gate-replacement"] -> {:ok, [issue]} end,
                   handoff_gate_poller: poller,
                   handoff_gate_sleep: fn _milliseconds -> :ok end,
                   linear_client: linear_client,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received :unchanged_gate_polled
      assert_received :replacement_gate_adopted
      assert_received :replacement_gate_polled
      assert_received :replacement_gate_handoff_applied
      assert_received {:agent_lifecycle, "issue-gate-replacement", :handoff_pending_gate, %{gate_job_id: "job-7157"}}

      assert_received {:agent_lifecycle, "issue-gate-replacement", :handoff_pending_gate, %{gate_job_id: "job-86814"}}

      refute_received {:agent_lifecycle, "issue-gate-replacement", :handoff_pending_gate, %{gate_job_id: "job-7157"}}

      assert_received {:agent_lifecycle, "issue-gate-replacement", :implementing, %{gate_job_id: "job-86814", gate_outcome: :passed}}

      refute_received :turn_ran
      assert {:ok, nil} = Workspace.load_handoff_gate_state(workspace)
    end

    test "finishes the owned lifecycle when a terminal replacement cannot be adopted" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-gate-terminal-replacement-#{System.unique_integer([:positive])}"
        )

      workspace = Path.join(workspace_root, "UDPE-7372")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-terminal-gate-replacement",
        identifier: "UDPE-7372",
        title: "Finish an invalidated replacement gate",
        state: "In Progress",
        labels: []
      }

      request = %{
        query: "mutation Move { issueUpdate(id: \"issue-terminal-gate-replacement\", input: {stateId: \"review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        target_state: "In Review",
        gate: async_gate(:pending),
        linear_client: fn _query, _variables, _opts -> {:ok, %{}} end
      }

      Application.put_env(:symphony_elixir, :pending_gate_recipient_for_test, self())
      Application.put_env(:symphony_elixir, :pending_gate_request_for_test, request)
      {:ok, state_reads} = Agent.start_link(fn -> 0 end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pending_gate_recipient_for_test)
        Application.delete_env(:symphony_elixir, :pending_gate_request_for_test)
        if Process.alive?(state_reads), do: Agent.stop(state_reads)
        File.rm_rf(workspace_root)
      end)

      terminal_gate = %{
        async_gate(:invalidated)
        | job_id: "job-replacement",
          candidate_hash: "candidate-replacement",
          summary: "candidate changed"
      }

      poller = fn _workspace, _issue, nil, "In Review", "job-7157", _opts ->
        {:invalidated, "candidate changed", terminal_gate}
      end

      state_fetcher = fn ["issue-terminal-gate-replacement"] ->
        read = Agent.get_and_update(state_reads, fn count -> {count, count + 1} end)
        state = if read == 0, do: "In Progress", else: "Done"
        {:ok, [%{issue | state: state}]}
      end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 self(),
                 [
                   agent_backend: {PendingGateBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   handoff_gate_poller: poller,
                   handoff_gate_sleep: fn _milliseconds -> :ok end,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received {:agent_lifecycle, "issue-terminal-gate-replacement", :handoff_pending_gate, %{gate_job_id: "job-7157"}}

      assert_received {:agent_lifecycle, "issue-terminal-gate-replacement", :implementing, %{gate_job_id: "job-7157", gate_outcome: :invalidated}}
    end

    test "ends the worker attempt on handoff infrastructure failure without a remediation turn" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-gate-infrastructure-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "UDPE-7157")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-gate-infrastructure",
        identifier: "UDPE-7157",
        title: "Back off after gate infrastructure failure",
        state: "In Progress",
        labels: []
      }

      request = %{
        query: "mutation Move { issueUpdate(id: \"issue-gate-infrastructure\", input: {stateId: \"review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        target_state: "In Review",
        gate: async_gate(:pending),
        linear_client: fn _query, _variables, _opts -> {:ok, %{}} end
      }

      Application.put_env(:symphony_elixir, :pending_gate_recipient_for_test, self())
      Application.put_env(:symphony_elixir, :pending_gate_request_for_test, request)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pending_gate_recipient_for_test)
        Application.delete_env(:symphony_elixir, :pending_gate_request_for_test)
        File.rm_rf(workspace_root)
      end)

      poller = fn _workspace, _issue, nil, "In Review", "job-7157", _opts ->
        gate = %{async_gate(:infrastructure_error) | summary: "gate runner unavailable"}
        {:infrastructure_error, "gate runner unavailable", gate}
      end

      state_fetcher = fn ["issue-gate-infrastructure"] -> {:ok, [issue]} end

      assert {:error, {:handoff_gate_infrastructure, %{message: "gate runner unavailable", gate: %{status: :infrastructure_error}}}} =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {PendingGateBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   handoff_gate_poller: poller,
                   handoff_gate_sleep: fn _milliseconds -> :ok end,
                   max_turns: 5
                 ],
                 nil
               )

      assert_received {:pending_gate_turn, 1, _initial_prompt}
      refute_received {:pending_gate_turn, 2, _remediation_prompt}
      refute_received {:memory_tracker_state_update, "issue-gate-infrastructure", "Blocked"}
      refute_received {:memory_tracker_add_label, "issue-gate-infrastructure", "needs-human-input"}
    end

    test "coalesces repeated requests for the same candidate into one durable job" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-gate-coalesce-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "UDPE-7157")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-gate-coalesce",
        identifier: "UDPE-7157",
        title: "Coalesce pending gate",
        state: "In Progress",
        labels: []
      }

      request = %{
        query: "mutation Move { issueUpdate(id: \"issue-gate-coalesce\", input: {stateId: \"review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        target_state: "In Review",
        gate: async_gate(:pending),
        linear_client: fn _query, _variables, _opts -> {:ok, %{}} end
      }

      on_exit(fn -> File.rm_rf(workspace_root) end)

      assert :ok = AgentRunner.store_deferred_handoff_gate_for_test(request)
      assert :already_pending = AgentRunner.store_deferred_handoff_gate_for_test(request)

      assert {:ok, %{"gate" => %{"jobId" => "job-7157"}}} =
               Workspace.load_handoff_gate_state(workspace)
    end

    test "a terminal gate failure gets one remediation turn even at max_turns" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-gate-remediation-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "UDPE-7157")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-gate-remediation",
        identifier: "UDPE-7157",
        title: "Resume after failed gate",
        state: "In Progress",
        labels: []
      }

      request = %{
        query: "mutation Move { issueUpdate(id: \"issue-gate-remediation\", input: {stateId: \"review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        target_state: "In Review",
        gate: async_gate(:pending),
        linear_client: fn _query, _variables, _opts -> {:ok, %{}} end
      }

      Application.put_env(:symphony_elixir, :pending_gate_recipient_for_test, self())
      Application.put_env(:symphony_elixir, :pending_gate_request_for_test, request)
      {:ok, state_reads} = Agent.start_link(fn -> 0 end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pending_gate_recipient_for_test)
        Application.delete_env(:symphony_elixir, :pending_gate_request_for_test)
        if Process.alive?(state_reads), do: Agent.stop(state_reads)
        File.rm_rf(workspace_root)
      end)

      state_fetcher = fn ["issue-gate-remediation"] ->
        read = Agent.get_and_update(state_reads, fn count -> {count, count + 1} end)
        state = if read < 2, do: "In Progress", else: "Done"
        {:ok, [%{issue | state: state}]}
      end

      failed_gate = %{async_gate(:failed) | remediation: "Fix the failing exact-head tests."}

      poller = fn _workspace, _issue, nil, "In Review", "job-7157", _opts ->
        {:failed, "Fix the failing exact-head tests.", failed_gate}
      end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {PendingGateBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   handoff_gate_poller: poller,
                   handoff_gate_sleep: fn _milliseconds -> :ok end,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received {:pending_gate_turn, 1, _initial_prompt}
      assert_received {:pending_gate_turn, 2, remediation_prompt}
      assert remediation_prompt =~ "Fix the failing exact-head tests."
      refute_received {:pending_gate_turn, 3, _prompt}
    end
  end

  describe "max-turn session boundary" do
    test "ends the worker session without changing the issue to Blocked" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-max-turn-boundary-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      Application.put_env(:symphony_elixir, :turn_count_recipient_for_test, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :turn_count_recipient_for_test)
        File.rm_rf(workspace)
      end)

      issue = %Issue{
        id: "issue-max-turn-boundary",
        identifier: "UDPE-7007",
        title: "Leave an active issue active",
        state: "In Progress",
        labels: []
      }

      state_fetcher = fn ["issue-max-turn-boundary"] -> {:ok, [issue]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {TurnCountingBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received :turn_ran
      refute_received :turn_ran
      refute_received {:memory_tracker_comment, "issue-max-turn-boundary", _body}
      refute_received {:memory_tracker_add_label, "issue-max-turn-boundary", _label}
      refute_received {:memory_tracker_state_update, "issue-max-turn-boundary", _state}
    end
  end

  describe "blocked mid-run halts continuation" do
    test "an agent transitioning its issue to Blocked stops being continued that turn" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-blocked-halt-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)

      Application.put_env(:symphony_elixir, :turn_count_recipient_for_test, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :turn_count_recipient_for_test)
        File.rm_rf(workspace)
      end)

      issue = %Issue{
        id: "issue-blocked-halt",
        identifier: "UDPE-6954",
        title: "Stuck and self-reporting Blocked",
        state: "In Progress",
        labels: []
      }

      # The agent transitions the issue to Blocked during turn 1 (its sanctioned
      # "stop dispatching me" channel). The turn loop's post-turn state refresh
      # must observe the now-inactive state and end the run instead of driving
      # the remaining continuation turns.
      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Blocked"}]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {TurnCountingBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 5
                 ],
                 nil
               )

      # Exactly one turn ran: the Blocked transition ended the run rather than
      # burning the other four continuation turns.
      assert_received :turn_ran
      refute_received :turn_ran
    end
  end

  defp async_gate(status) do
    %{
      protocol_version: 1,
      job_id: "job-7157",
      status: status,
      identity: %{"candidateHash" => "candidate-7157", "exactHash" => "exact-7157"},
      candidate_hash: "candidate-7157",
      exact_hash: "exact-7157",
      heartbeat_at: "2026-08-02T12:00:00Z",
      heartbeat_age_ms: 10,
      next_poll_ms: 1,
      progress: %{"stage" => "ci", "completed" => 1, "total" => 2},
      started_at: "2026-08-02T11:59:00Z",
      completed_at: if(status == :passed, do: "2026-08-02T12:01:00Z", else: nil),
      result_artifact: nil,
      checks: [],
      remediation: nil,
      summary: nil,
      single_flight: true
    }
  end

  defp prompt_position(prompt, marker) do
    case :binary.match(prompt, marker) do
      {position, _length} -> position
      :nomatch -> flunk("expected prompt marker #{inspect(marker)}")
    end
  end

  defp counting_manifest_runner(expected_workspace, opts \\ []) do
    {:ok, state} =
      Agent.start_link(fn ->
        %{head_calls: 0, numstat_calls: 0, numstat_path_counts: [], cwds: []}
      end)

    paths = Enum.map_join(1..70, "\n", &"lib/path-#{&1}.ex") <> "\n"

    fail_head_calls = MapSet.new(Keyword.get(opts, :fail_head_calls, []))

    runner = fn args, cwd ->
      Agent.update(state, &Map.update!(&1, :cwds, fn values -> [cwd | values] end))
      assert cwd == expected_workspace

      case args do
        ["rev-parse", "HEAD"] ->
          head_probe_result(state, fail_head_calls)

        ["diff", "--name-only", "HEAD"] ->
          {paths, 0}

        ["diff", "--name-only", "--cached"] ->
          {"", 0}

        ["ls-files", "--others", "--exclude-standard"] ->
          {"", 0}

        ["status", "--porcelain", "--untracked-files=normal"] ->
          {" M lib/path-1.ex\n", 0}

        ["hash-object", "--no-filters", "--" | selected] ->
          {Enum.map_join(selected, "\n", fn _path -> String.duplicate("c", 40) end) <> "\n", 0}

        ["diff", "--numstat", "HEAD", "--" | selected] ->
          numstat_probe_result(state, selected)
      end
    end

    {runner, state}
  end

  defp increment_head_calls(state) do
    Agent.get_and_update(state, fn current ->
      call = current.head_calls + 1
      {call, %{current | head_calls: call}}
    end)
  end

  defp head_probe_result(state, fail_head_calls) do
    if MapSet.member?(fail_head_calls, increment_head_calls(state)),
      do: {"transient head probe failure", 17},
      else: {String.duplicate("b", 40) <> "\n", 0}
  end

  defp numstat_probe_result(state, selected) do
    Agent.update(state, fn current ->
      current
      |> Map.update!(:numstat_calls, &(&1 + 1))
      |> Map.update!(:numstat_path_counts, &[length(selected) | &1])
    end)

    {Enum.map_join(selected, "\n", &"1\t0\t#{&1}") <> "\n", 0}
  end

  defp prepare_progress_repository!(identifier) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-repository-progress-#{System.unique_integer([:positive])}"
      )

    origin = Path.join(root, "origin")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(origin)
    on_exit(fn -> File.rm_rf(root) end)

    System.cmd("git", ["-C", origin, "init", "--quiet", "--initial-branch", "main"])
    System.cmd("git", ["-C", origin, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", origin, "config", "user.email", "test@example.com"])

    File.write!(
      Path.join(origin, "WORKFLOW.md"),
      """
      ---
      hooks:
        before_run: printf before > progress.txt
      ---
      Test repository progress.
      """
    )

    System.cmd("git", ["-C", origin, "add", "WORKFLOW.md"])
    System.cmd("git", ["-C", origin, "commit", "--quiet", "-m", "initial"])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    File.write!(
      Application.fetch_env!(:symphony_elixir, :repo_config_path),
      """
      linear:
        team_id: UDPE
      repos:
        - id: progress-repo
          label: repo:progress-repo
          repo_url: #{origin}
          workflow_path: WORKFLOW.md
          base_branch: main
      """
    )

    issue = %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Track repository material progress",
      state: "In Progress",
      labels: ["repo:progress-repo"],
      comments: []
    }

    {issue, workspace_root}
  end
end
