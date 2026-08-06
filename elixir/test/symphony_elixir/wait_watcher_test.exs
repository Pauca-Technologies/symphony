defmodule SymphonyElixir.WaitWatcherTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{WaitCondition, WaitStore, WaitWatcher}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-waits-#{System.unique_integer([:positive])}")
    state_path = Path.join(root, "waits.json")
    previous_path = Application.get_env(:symphony_elixir, :wait_state_path)
    previous_probe = Application.get_env(:symphony_elixir, :wait_condition_probe)
    Application.put_env(:symphony_elixir, :wait_state_path, state_path)

    on_exit(fn ->
      restore_app_env(:wait_state_path, previous_path)
      restore_app_env(:wait_condition_probe, previous_probe)
      File.rm_rf(root)
    end)

    %{state_path: state_path}
  end

  test "normalizes the supported typed conditions" do
    context = %{workspace: "/tmp/workspace", worker_host: nil, issue: %{id: "issue-1"}}

    assert {:ok, git} =
             WaitCondition.normalize(
               %{
                 "reason" => "base branch has not advanced",
                 "condition" => %{
                   "type" => "git_ref_changed",
                   "ref" => "refs/heads/main",
                   "observed" => "abc123"
                 }
               },
               context
             )

    assert git.condition["observed"] == "abc123"
    assert git.condition["workspace"] == "/tmp/workspace"

    assert {:ok, linear} =
             WaitCondition.normalize(
               %{
                 "reason" => "await issue update",
                 "condition" => %{"type" => "linear_issue_changed", "observed" => "2026-08-06T00:00:00Z"}
               },
               context
             )

    assert linear.condition["issue_id"] == "issue-1"
  end

  test "deduplicates identical probes and persists ready work", %{state_path: state_path} do
    test_pid = self()

    Application.put_env(:symphony_elixir, :wait_condition_probe, fn request ->
      send(test_pid, {:probe, request.condition_key})

      receive do
        :release_probe -> :ok
      end

      {:changed, %{"status" => "operational"}}
    end)

    name = :"wait-watcher-#{System.unique_integer([:positive])}"
    start_supervised!({WaitWatcher, name: name})

    request = %{
      condition: %{"type" => "github_actions_recovered", "component" => "Actions"},
      condition_key: "shared-actions-condition",
      reason: "GitHub Actions outage",
      min_poll_ms: 15_000,
      max_poll_ms: 60_000
    }

    :ok = WaitWatcher.park(name, entry("issue-1", "UDPE-1", request))
    assert_receive {:probe, "shared-actions-condition"}, 1_000
    :ok = WaitWatcher.park(name, entry("issue-2", "UDPE-2", request))
    probe_pid = :sys.get_state(name).probes[request.condition_key].pid
    send(probe_pid, :release_probe)
    refute_receive {:probe, "shared-actions-condition"}, 100

    assert eventually(fn -> Enum.all?(WaitWatcher.snapshot(name), &(&1.status == :ready)) end)
    assert File.exists?(state_path)
    assert MapSet.new(Map.keys(WaitStore.load())) == MapSet.new(["issue-1", "issue-2"])

    :ok = WaitWatcher.acknowledge(name, "issue-1")
    assert WaitWatcher.issue_ids(name) == MapSet.new(["issue-2"])
  end

  test "manual resume produces a compact resume prompt" do
    Application.put_env(:symphony_elixir, :wait_condition_probe, fn _request ->
      {:unchanged, %{"status" => "degraded"}}
    end)

    name = :"wait-watcher-#{System.unique_integer([:positive])}"
    start_supervised!({WaitWatcher, name: name})

    request = %{
      condition: %{"type" => "github_actions_recovered", "component" => "Actions"},
      condition_key: "manual-actions-condition",
      reason: "outage",
      min_poll_ms: 15_000,
      max_poll_ms: 60_000
    }

    :ok = WaitWatcher.park(name, entry("issue-3", "UDPE-3", request))
    assert {:ok, ready} = WaitWatcher.resume_now(name, "UDPE-3")
    assert ready.status == :ready
    assert ready.resume_prompt =~ "human requested an immediate resume"
    assert ready.resume_prompt =~ "Do not repeat the old polling loop"
  end

  defp entry(issue_id, identifier, request) do
    %{
      issue_id: issue_id,
      identifier: identifier,
      title: "Waiting issue",
      backend: "codex",
      worker_host: nil,
      workspace_path: "/tmp/#{identifier}",
      priority: 1,
      created_at: DateTime.utc_now(),
      request: request
    }
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
