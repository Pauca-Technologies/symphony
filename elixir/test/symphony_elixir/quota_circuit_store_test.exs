defmodule SymphonyElixir.QuotaCircuitStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.QuotaCircuitStore

  test "persists outage deadlines and parked retry order across restart" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    next_probe_at = DateTime.add(now, 3_600, :second)

    circuits = %{
      "codex::worker:worker-a" => %{
        backend: "codex",
        account_scope: "worker:worker-a",
        worker_host: "worker-a",
        provider_limit_id: "premium",
        status: :probe,
        reason: "quota exhausted",
        opened_at: now,
        reset_at: next_probe_at,
        next_probe_at: next_probe_at,
        probe_issue_id: "issue-probe",
        parked: [
          %{
            issue_id: "issue-a",
            identifier: "MT-1",
            title: "First",
            attempt: 2,
            error: "quota exhausted",
            backend: "codex",
            failure_class: :usage_quota_limit,
            worker_host: nil,
            workspace_path: "/tmp/workspace-a",
            parked_at: now
          },
          %{
            issue_id: "issue-b",
            identifier: "MT-2",
            title: "Second",
            attempt: 1,
            error: "quota exhausted",
            backend: "codex",
            worker_host: "worker-a",
            workspace_path: "/tmp/workspace-b",
            parked_at: DateTime.add(now, 1, :second)
          }
        ],
        timer_ref: make_ref(),
        timer_token: make_ref()
      }
    }

    assert :ok = QuotaCircuitStore.save(circuits)
    restored = QuotaCircuitStore.load()

    assert %{
             status: :open,
             account_scope: "worker:worker-a",
             worker_host: "worker-a",
             provider_limit_id: "premium",
             reset_at: ^next_probe_at,
             next_probe_at: ^next_probe_at,
             probe_issue_id: nil,
             parked: [
               %{
                 issue_id: "issue-a",
                 failure_class: :usage_quota_limit,
                 retry_id: nil,
                 previous_retry_id: nil,
                 parent_run_id: nil
               },
               %{issue_id: "issue-b", retry_id: nil, previous_retry_id: nil, parent_run_id: nil}
             ]
           } = restored["codex::worker:worker-a"]
  end

  test "invalid persisted state fails closed to an empty map" do
    File.write!(QuotaCircuitStore.path(), "not json")
    assert QuotaCircuitStore.load() == %{}
  end
end
