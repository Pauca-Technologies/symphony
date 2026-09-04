defmodule SymphonyElixir.ExperimentRuntimeTest.Backend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(workspace, opts) do
    config = Application.fetch_env!(:symphony_elixir, :experiment_runtime_backend)
    send(config.owner, {:experiment_session, workspace, opts})
    {:ok, %{worker_host: nil, workspace: workspace}}
  end

  @impl true
  def run_turn(session, prompt, _issue, opts) do
    config = Application.fetch_env!(:symphony_elixir, :experiment_runtime_backend)
    turn = Agent.get_and_update(config.turns, fn current -> {current + 1, current + 1} end)
    packet = SymphonyElixir.Workspace.load_resume_packet(session.workspace)
    send(config.owner, {:experiment_turn, turn, prompt, opts, packet})

    case Map.get(config.results, turn, :ok) do
      :ok -> {:ok, %{session_id: "experiment-runtime-#{turn}"}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.ExperimentRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentRunner, Experiment, ResumePacket, Telemetry, Workspace}
  alias SymphonyElixir.Config.Experiment, as: ExperimentConfig
  alias SymphonyElixir.ExperimentRuntimeTest.Backend
  alias SymphonyElixir.Linear.Issue

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-experiment-runtime-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :telemetry_enabled, true)

    {:ok, turns} = Agent.start_link(fn -> 0 end)

    Application.put_env(:symphony_elixir, :experiment_runtime_backend, %{
      owner: self(),
      turns: turns,
      results: %{}
    })

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :experiment_runtime_backend)
      if Process.alive?(turns), do: Agent.stop(turns)
      File.rm_rf(root)
    end)

    %{root: root, turns: turns}
  end

  test "applies deterministic control and variant effort with manifest and exposure provenance", %{root: root} do
    workflow = experiment_workflow()
    {:ok, manifest} = ExperimentConfig.parse(workflow.config)

    manifests =
      for role <- ~w(control variant) do
        issue = issue_for_role(manifest, role)
        workspace = workspace(root, issue.identifier)
        counters = counters()

        assert :ok = run(workspace, issue, workflow, counters, run_id: "run-#{role}")

        assert_receive {:experiment_session, ^workspace, session_opts}
        assert session_opts[:overrides][:reasoning_effort] == "xhigh"

        assert_receive {:experiment_turn, _turn, prompt, turn_opts, {:ok, packet}}
        assignment = packet["experiment_assignment"]
        assert assignment["arm_role"] == role
        assert turn_opts[:reasoning_effort] == assignment["reasoning_effort"]
        status_packet = "Symphony status/resume packet" <> List.last(String.split(prompt, "Symphony status/resume packet"))
        refute status_packet =~ assignment["experiment_id"]
        refute prompt =~ assignment["assignment_id"]
        refute status_packet =~ "experiment_assignment"

        assert Agent.get(counters, & &1) == %{loads: 1, repository_refreshes: 1}

        events = events_for_run("run-#{role}")
        assert [%{"exposure_id" => exposure_id} = exposure] = Enum.filter(events, &(&1["event"] == "experiment_exposure"))
        assert exposure_id == assignment["last_exposure_id"]
        assert exposure["arm_id"] == assignment["arm_id"]
        assert exposure["assignment_reason"] == "deterministic_opt_in"
        assert exposure["reasoning_effort"] == assignment["reasoning_effort"]
        refute Map.has_key?(exposure, "labels")

        manifest_event = Enum.find(events, &(&1["event"] == "run_manifest"))
        assert get_in(manifest_event, ["configuration", "experiment", "arm_id"]) == assignment["arm_id"]
        refute inspect(manifest_event) =~ workflow_label()
        refute inspect(exposure) =~ workflow_label()

        {role, manifest_event}
      end

    assert {"control", control_manifest} = List.keyfind(manifests, "control", 0)
    assert {"variant", variant_manifest} = List.keyfind(manifests, "variant", 0)
    refute control_manifest["config_digest"] == variant_manifest["config_digest"]
  end

  test "same run has one exposure, continuation has no duplicate, and retry has a new exposure", %{root: root} do
    workflow = experiment_workflow()
    {:ok, manifest} = ExperimentConfig.parse(workflow.config)
    issue = issue_for_role(manifest, "variant")
    workspace = workspace(root, issue.identifier)
    counters = counters()

    assert :ok =
             run(workspace, issue, workflow, counters,
               run_id: "run-original",
               max_turns: 2,
               active_turns: 1
             )

    assert_receive {:experiment_session, ^workspace, _opts}
    assert_receive {:experiment_turn, _turn, _prompt1, opts1, {:ok, first_packet}}
    assert_receive {:experiment_turn, _turn, _prompt2, opts2, {:ok, second_packet}}
    assert opts1[:reasoning_effort] == opts2[:reasoning_effort]

    assert get_in(first_packet, ["experiment_assignment", "last_exposure_id"]) ==
             get_in(second_packet, ["experiment_assignment", "last_exposure_id"])

    assert Agent.get(counters, & &1) == %{loads: 1, repository_refreshes: 2}

    original_exposure =
      events_for_run("run-original")
      |> Enum.filter(&(&1["event"] == "experiment_exposure"))

    assert [%{"exposure_id" => original_exposure_id}] = original_exposure

    assert :ok = run(workspace, issue, workflow, counters, run_id: "run-original")
    assert_receive {:experiment_session, ^workspace, _opts}
    assert_receive {:experiment_turn, _turn, _prompt, _opts, {:ok, restarted_packet}}

    assert get_in(restarted_packet, ["experiment_assignment", "last_exposure_id"]) ==
             original_exposure_id

    replayed_exposures =
      events_for_run("run-original")
      |> Enum.filter(&(&1["event"] == "experiment_exposure"))

    assert length(replayed_exposures) == 2
    assert replayed_exposures |> Enum.map(& &1["exposure_id"]) |> Enum.uniq() == [original_exposure_id]

    assert :ok =
             run(workspace, issue, workflow, counters,
               run_id: "run-retry",
               parent_run_id: "run-original",
               retry_id: "retry-1",
               retry_attempt: 1
             )

    assert_receive {:experiment_session, ^workspace, _opts}
    assert_receive {:experiment_turn, _turn, _prompt, _opts, {:ok, retry_packet}}
    retry_exposure_id = get_in(retry_packet, ["experiment_assignment", "last_exposure_id"])
    refute retry_exposure_id == original_exposure_id

    assert [%{"exposure_id" => ^retry_exposure_id}] =
             events_for_run("run-retry")
             |> Enum.filter(&(&1["event"] == "experiment_exposure"))
  end

  test "off before the first controlled turn suspends permanently and re-enable stays baseline", %{root: root} do
    workflow = experiment_workflow()
    {:ok, manifest} = ExperimentConfig.parse(workflow.config)
    issue = issue_for_role(manifest, "variant")
    workspace = workspace(root, issue.identifier)
    counters = counters()
    mode = mode_sequence([:apply, :off])

    assert :ok = run(workspace, issue, workflow, counters, run_id: "run-off", mode: mode)
    assert_receive {:experiment_session, ^workspace, _opts}
    assert_receive {:experiment_turn, _turn, _prompt, turn_opts, {:ok, packet}}
    assert turn_opts[:reasoning_effort] == "xhigh"
    assert packet["experiment_assignment"]["state"] == "suspended"
    refute packet["experiment_assignment"]["ever_exposed"]

    events = events_for_run("run-off")
    assert Enum.filter(events, &(&1["event"] == "experiment_exposure")) == []

    assert [%{"reason" => "kill_switch", "suspension_id" => suspension_id}] =
             Enum.filter(events, &(&1["event"] == "experiment_suspended"))

    assert :ok =
             run(workspace, issue, workflow, counters,
               run_id: "run-reenabled",
               parent_run_id: "run-off",
               retry_attempt: 1,
               mode: fn -> :apply end
             )

    assert_receive {:experiment_session, ^workspace, _opts}
    assert_receive {:experiment_turn, _turn, _prompt, reenabled_opts, {:ok, reenabled_packet}}
    assert reenabled_opts[:reasoning_effort] == "xhigh"
    assert reenabled_packet["experiment_assignment"]["suspension_id"] == suspension_id

    assert [
             %{
               "event" => "experiment_suspended",
               "suspension_id" => ^suspension_id,
               "delivery" => "replay"
             }
           ] =
             Enum.filter(
               events_for_run("run-reenabled"),
               &(&1["event"] in ~w(experiment_exposure experiment_suspended))
             )
  end

  test "off after exposure switches the next turn to baseline and emits one suspension", %{root: root} do
    workflow = experiment_workflow()
    {:ok, manifest} = ExperimentConfig.parse(workflow.config)
    issue = issue_for_role(manifest, "variant")
    workspace = workspace(root, "off-after-exposure")
    counters = counters()
    mode = mode_sequence([:apply, :apply, :off])

    assert :ok =
             run(workspace, issue, workflow, counters,
               run_id: "run-off-after",
               max_turns: 2,
               active_turns: 1,
               mode: mode
             )

    assert_receive {:experiment_session, ^workspace, _opts}
    assert_receive {:experiment_turn, _turn, _prompt, first_opts, {:ok, first_packet}}
    assert_receive {:experiment_turn, _turn, _prompt, second_opts, {:ok, second_packet}}
    assert first_opts[:reasoning_effort] == "low"
    assert second_opts[:reasoning_effort] == "xhigh"
    assert first_packet["experiment_assignment"]["state"] == "active"
    assert second_packet["experiment_assignment"]["state"] == "suspended"

    events = events_for_run("run-off-after")
    assert length(Enum.filter(events, &(&1["event"] == "experiment_exposure"))) == 1
    assert [%{"reason" => "kill_switch"}] = Enum.filter(events, &(&1["event"] == "experiment_suspended"))
  end

  test "manifest mismatch suspends restored assignment rather than reassigning", %{root: root} do
    workflow = experiment_workflow()
    {:ok, manifest} = ExperimentConfig.parse(workflow.config)
    issue = issue_for_role(manifest, "variant")
    workspace = workspace(root, "manifest-mismatch")
    counters = counters()

    assert :ok = run(workspace, issue, workflow, counters, run_id: "run-before-mismatch")
    assert_receive {:experiment_session, ^workspace, _opts}
    assert_receive {:experiment_turn, _turn, _prompt, _opts, {:ok, before_packet}}
    original_assignment_id = before_packet["experiment_assignment"]["assignment_id"]

    assert :ok =
             run(workspace, issue, experiment_workflow(2), counters,
               run_id: "run-after-mismatch",
               parent_run_id: "run-before-mismatch",
               retry_attempt: 1
             )

    assert_receive {:experiment_session, ^workspace, _opts}
    assert_receive {:experiment_turn, _turn, _prompt, turn_opts, {:ok, mismatch_packet}}
    assignment = mismatch_packet["experiment_assignment"]
    assert turn_opts[:reasoning_effort] == "xhigh"
    assert assignment["assignment_id"] == original_assignment_id
    assert assignment["state"] == "suspended"
    assert assignment["suspension_reason"] == "manifest_mismatch"

    events = events_for_run("run-after-mismatch")
    assert Enum.filter(events, &(&1["event"] == "experiment_exposure")) == []

    assert [%{"reason" => "manifest_mismatch"}] =
             Enum.filter(events, &(&1["event"] == "experiment_suspended"))
  end

  test "route mismatch suspends without passing Codex effort to another backend", %{root: root} do
    workflow = experiment_workflow()
    {:ok, manifest} = ExperimentConfig.parse(workflow.config)
    issue = issue_for_role(manifest, "variant")
    workspace = workspace(root, "route-mismatch")
    counters = counters()

    assert :ok = run(workspace, issue, workflow, counters, run_id: "run-before-route-change")
    assert_receive {:experiment_session, ^workspace, _opts}
    assert_receive {:experiment_turn, _turn, _prompt, _opts, {:ok, _packet}}

    assert :ok =
             run(workspace, issue, workflow, counters,
               run_id: "run-route-change",
               parent_run_id: "run-before-route-change",
               retry_attempt: 1,
               backend_name: "acp"
             )

    assert_receive {:experiment_session, ^workspace, _opts}
    assert_receive {:experiment_turn, _turn, _prompt, turn_opts, {:ok, packet}}
    refute Keyword.has_key?(turn_opts, :reasoning_effort)
    assert packet["experiment_assignment"]["suspension_reason"] == "route_mismatch"

    assert [%{"reason" => "route_mismatch"}] =
             events_for_run("run-route-change")
             |> Enum.filter(&(&1["event"] == "experiment_suspended"))
  end

  test "malformed persisted assignment is dropped without exposing packet content", %{root: root} do
    workflow = experiment_workflow()
    {:ok, manifest} = ExperimentConfig.parse(workflow.config)
    issue = issue_for_role(manifest, "variant")
    workspace = workspace(root, "malformed-assignment")
    poison = "PROMPT\nINJECTION raw assignment"

    malformed =
      ResumePacket.build(
        %{
          issue: issue,
          identity: %{run_id: "old-run", retry_attempt: 0},
          experiment_assignment: %{"raw" => poison}
        },
        now: ~U[2026-09-03 00:00:00Z]
      )

    assert :ok = Workspace.persist_resume_packet(workspace, malformed)
    counters = counters()

    assert :ok =
             run(workspace, issue, workflow, counters,
               run_id: "run-malformed-assignment",
               parent_run_id: "old-run",
               retry_attempt: 1
             )

    assert_receive {:experiment_session, ^workspace, _opts}
    assert_receive {:experiment_turn, _turn, prompt, turn_opts, {:ok, packet}}
    refute Keyword.has_key?(turn_opts, :reasoning_effort)
    refute Map.has_key?(packet, "experiment_assignment")
    refute prompt =~ poison
    assert "experiment.assignment_invalid" in packet["errors"]["codes"]
  end

  test "packet persistence failure is nonblocking and replay keeps one logical exposure id", %{root: root} do
    workflow = experiment_workflow()
    {:ok, manifest} = ExperimentConfig.parse(workflow.config)
    issue = issue_for_role(manifest, "variant")
    outside_workspace = root <> "-outside"
    counters = counters()

    for _attempt <- 1..2 do
      assert :ok =
               run(outside_workspace, issue, workflow, counters,
                 run_id: "run-persist-failure",
                 packet_loader_result: {:ok, nil, []}
               )

      assert_receive {:experiment_session, ^outside_workspace, _opts}
      assert_receive {:experiment_turn, _turn, _prompt, turn_opts, {:error, _read_error}}
      assert turn_opts[:reasoning_effort] == "low"
    end

    exposures =
      events_for_run("run-persist-failure")
      |> Enum.filter(&(&1["event"] == "experiment_exposure"))

    assert [first, second] = exposures
    assert first["exposure_id"] == second["exposure_id"]
    assert {:error, _reason} = Workspace.load_resume_packet(outside_workspace)
  end

  test "an unavailable prior packet cannot be mistaken for fresh experiment lineage", %{root: root} do
    workflow = experiment_workflow()
    {:ok, manifest} = ExperimentConfig.parse(workflow.config)
    issue = issue_for_role(manifest, "variant")
    workspace = workspace(root, "unavailable-lineage")
    counters = counters()

    assert :ok =
             run(workspace, issue, workflow, counters,
               run_id: "run-unavailable-lineage",
               packet_loader_result: {:ok, nil, ["resume_packet_invalid"]}
             )

    assert_receive {:experiment_session, ^workspace, _opts}
    assert_receive {:experiment_turn, _turn, _prompt, turn_opts, {:ok, packet}}
    refute Keyword.has_key?(turn_opts, :reasoning_effort)
    refute Map.has_key?(packet, "experiment_assignment")
    assert "resume_packet_invalid" in packet["errors"]["codes"]

    refute Enum.any?(
             events_for_run("run-unavailable-lineage"),
             &String.starts_with?(&1["event"], "experiment_")
           )
  end

  test "malformed manifest and mode resolver failure stay on baseline without failing the turn", %{root: root} do
    malformed_workflow = %{
      prompt_template: "Implement the task with the configured workflow.",
      config: %{"agent" => %{"experiment" => %{"schema_version" => 99}}}
    }

    issue = %Issue{
      id: "issue-malformed-manifest",
      identifier: "UDPE-7505-malformed",
      title: "Malformed experiment manifest",
      state: "In Progress",
      labels: [workflow_label()],
      comments: []
    }

    manifest_workspace = workspace(root, "malformed-manifest")
    counters = counters()

    assert :ok =
             run(manifest_workspace, issue, malformed_workflow, counters, run_id: "run-malformed-manifest")

    assert_receive {:experiment_session, ^manifest_workspace, _opts}
    assert_receive {:experiment_turn, _turn, _prompt, manifest_opts, {:ok, manifest_packet}}
    refute Keyword.has_key?(manifest_opts, :reasoning_effort)
    refute Map.has_key?(manifest_packet, "experiment_assignment")
    assert "experiment.manifest_invalid" in manifest_packet["errors"]["codes"]

    workflow = experiment_workflow()
    {:ok, manifest} = ExperimentConfig.parse(workflow.config)
    assigned_issue = issue_for_role(manifest, "variant")
    mode_workspace = workspace(root, "mode-failure")
    {:ok, mode_calls} = Agent.start_link(fn -> 0 end)

    mode = fn ->
      case Agent.get_and_update(mode_calls, fn count -> {count + 1, count + 1} end) do
        1 -> :apply
        _later -> raise "mode source unavailable"
      end
    end

    assert :ok =
             run(mode_workspace, assigned_issue, workflow, counters,
               run_id: "run-mode-failure",
               mode: mode
             )

    Agent.stop(mode_calls)
    assert_receive {:experiment_session, ^mode_workspace, _opts}
    assert_receive {:experiment_turn, _turn, _prompt, mode_opts, {:ok, mode_packet}}
    assert mode_opts[:reasoning_effort] == "xhigh"
    assert mode_packet["experiment_assignment"]["state"] == "suspended"
    assert mode_packet["experiment_assignment"]["suspension_reason"] == "kill_switch"

    assert [%{"reason" => "kill_switch"}] =
             events_for_run("run-mode-failure")
             |> Enum.filter(&(&1["event"] == "experiment_suspended"))
  end

  test "legacy retry remains nonexperimental and handled error preserves an active assignment", %{root: root} do
    workflow = experiment_workflow()
    {:ok, manifest} = ExperimentConfig.parse(workflow.config)
    issue = issue_for_role(manifest, "variant")
    legacy_workspace = workspace(root, "legacy")
    legacy_packet = ResumePacket.build(%{issue: issue, identity: %{run_id: "legacy"}}, now: ~U[2026-09-03 00:00:00Z])
    assert :ok = Workspace.persist_resume_packet(legacy_workspace, legacy_packet)
    counters = counters()

    assert :ok =
             run(legacy_workspace, issue, workflow, counters,
               run_id: "run-legacy-retry",
               parent_run_id: "legacy",
               retry_attempt: 1
             )

    assert_receive {:experiment_session, ^legacy_workspace, _opts}
    assert_receive {:experiment_turn, _turn, prompt, turn_opts, {:ok, packet}}
    refute Keyword.has_key?(turn_opts, :reasoning_effort)
    refute Map.has_key?(packet, "experiment_assignment")
    refute prompt =~ "experiment_assignment"
    refute Enum.any?(events_for_run("run-legacy-retry"), &String.starts_with?(&1["event"], "experiment_"))

    legacy_manifest = Enum.find(events_for_run("run-legacy-retry"), &(&1["event"] == "run_manifest"))
    refute Map.has_key?(legacy_manifest["configuration"], "experiment")

    error_workspace = workspace(root, "handled-error")
    configure_backend_results(%{2 => {:error, :handled_error}})

    assert {:error, :handled_error} =
             run(error_workspace, issue, workflow, counters, run_id: "run-handled-error")

    assert_receive {:experiment_session, ^error_workspace, _opts}
    assert_receive {:experiment_turn, _turn, _prompt, error_opts, {:ok, start_packet}}
    assert is_binary(error_opts[:reasoning_effort])
    assert {:ok, final_packet} = Workspace.load_resume_packet(error_workspace)

    assert final_packet["experiment_assignment"]["assignment_id"] ==
             start_packet["experiment_assignment"]["assignment_id"]
  end

  defp run(workspace, issue, workflow, counters, opts) do
    max_turns = Keyword.get(opts, :max_turns, 1)
    active_turns = Keyword.get(opts, :active_turns, 0)
    {:ok, state_calls} = Agent.start_link(fn -> 0 end)

    result =
      AgentRunner.run_codex_turns_for_test(
        workspace,
        issue,
        nil,
        [
          agent_backend: {Backend, %{model: "test-model", reasoning_effort: "xhigh"}},
          experiment_backend_name: Keyword.get(opts, :backend_name, "codex"),
          experiment_mode_resolver: Keyword.get(opts, :mode, fn -> :apply end),
          resume_packet_loader: packet_loader(counters, Keyword.get(opts, :packet_loader_result, :delegate)),
          issue_state_fetcher: issue_state_fetcher(issue, state_calls, active_turns),
          per_repo_workflow: workflow,
          workflow_source: "repository:WORKFLOW.md",
          repository_id: "symphony",
          repository_manifest: repository_manifest(),
          repository_manifest_collector: repository_collector(counters),
          run_id: Keyword.fetch!(opts, :run_id),
          parent_run_id: Keyword.get(opts, :parent_run_id),
          retry_id: Keyword.get(opts, :retry_id),
          retry_attempt: Keyword.get(opts, :retry_attempt, 0),
          max_turns: max_turns
        ],
        nil
      )

    Agent.stop(state_calls)
    result
  end

  defp issue_state_fetcher(issue, calls, active_turns) do
    fn [_issue_id] ->
      call = Agent.get_and_update(calls, fn current -> {current + 1, current + 1} end)
      state = if call <= active_turns, do: "In Progress", else: "Done"
      {:ok, [%{issue | state: state}]}
    end
  end

  defp packet_loader(counters, result) do
    fn workspace, worker_host ->
      Agent.update(counters, &Map.update!(&1, :loads, fn count -> count + 1 end))

      case result do
        :delegate -> Workspace.load_resume_packet_with_diagnostics(workspace, worker_host)
        fixed -> fixed
      end
    end
  end

  defp repository_collector(counters) do
    fn _workspace, _base_ref, _opts ->
      Agent.update(counters, &Map.update!(&1, :repository_refreshes, fn count -> count + 1 end))
      repository_manifest()
    end
  end

  defp counters do
    {:ok, counters} = Agent.start_link(fn -> %{loads: 0, repository_refreshes: 0} end)
    on_exit(fn -> if Process.alive?(counters), do: Agent.stop(counters) end)
    counters
  end

  defp mode_sequence(modes) do
    {:ok, agent} = Agent.start_link(fn -> modes end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    fn ->
      Agent.get_and_update(agent, fn
        [mode | rest] -> {mode, if(rest == [], do: [mode], else: rest)}
        [] -> {:off, []}
      end)
    end
  end

  defp workspace(root, suffix) do
    path = Path.join(root, suffix)
    File.mkdir_p!(path)
    path
  end

  defp configure_backend_results(results) do
    current = Application.fetch_env!(:symphony_elixir, :experiment_runtime_backend)
    Application.put_env(:symphony_elixir, :experiment_runtime_backend, %{current | results: results})
  end

  defp events_for_run(run_id) do
    Telemetry.read_events(Date.utc_today(), Date.utc_today())
    |> Enum.filter(&(&1["run_id"] == run_id))
  end

  defp issue_for_role(manifest, role) do
    index =
      Enum.find(1..2_000, fn index ->
        context = %{
          fresh_task: true,
          mode: :apply,
          issue_id: "issue-#{index}",
          labels: [workflow_label()],
          repository_id: "symphony",
          task_family: "simple_direct",
          backend: "codex",
          baseline_reasoning_effort: "xhigh"
        }

        match?({:assigned, %{"arm_role" => ^role}}, Experiment.assign(manifest, context))
      end)

    %Issue{
      id: "issue-#{index}",
      identifier: "UDPE-7505-#{role}",
      title: "Exercise controlled effort assignment",
      state: "In Progress",
      labels: [workflow_label()],
      comments: []
    }
  end

  defp experiment_workflow(revision \\ 1) do
    %{
      prompt_template: "Implement the task with the configured workflow.",
      config: %{
        "agent" => %{
          "experiment" => %{
            "schema_version" => 1,
            "id" => "effort-runtime",
            "revision" => revision,
            "opt_in_label" => workflow_label(),
            "backend" => "codex",
            "repositories" => ["symphony"],
            "task_families" => ~w(simple_direct ui security_tenant data_schema concurrency_liveness broad_architecture),
            "variable" => "reasoning_effort",
            "control" => %{"id" => "control", "weight" => 1, "value" => "xhigh"},
            "variants" => [%{"id" => "low", "weight" => 1, "value" => "low"}]
          }
        }
      }
    }
  end

  defp workflow_label, do: "experiment:effort-runtime"

  defp repository_manifest do
    %{
      head_sha: String.duplicate("a", 40),
      base_sha: String.duplicate("b", 40),
      candidate_base_sha: nil,
      actual_paths: [],
      dirty: false,
      diff_counts: %{files: 0, additions: 0, deletions: 0},
      worktree_status_fingerprint: String.duplicate("1", 64),
      worktree_content_fingerprint: String.duplicate("2", 64),
      worktree_fingerprint_complete: true,
      errors: []
    }
  end
end
