defmodule SymphonyElixir.TestWorkerBudgetTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.TestWorkerBudget

  test "exports and explains a configurable per-agent limit without changing agent slots" do
    write_workflow_file!(Workflow.workflow_file_path(),
      max_concurrent_agents: 10,
      test_worker_limit: 3
    )

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.settings!().agent.test_worker_limit == 3
    assert TestWorkerBudget.port_env() == [{~c"SYMPHONY_TEST_WORKER_LIMIT", ~c"3"}]
    assert TestWorkerBudget.shell_export() == "export SYMPHONY_TEST_WORKER_LIMIT=3"

    section = TestWorkerBudget.prompt_section()
    assert section.content =~ "within 3 concurrent worker processes"
    assert section.content =~ "vitest --maxWorkers=3"
    assert section.content =~ "playwright test --workers=3"
    assert section.content =~ "does not reduce Symphony's agent concurrency"
  end

  test "defaults to two test workers and rejects unsafe values" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.agent.test_worker_limit == 2

    for value <- [0, 33] do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"test_worker_limit" => value}})

      assert message =~ "test_worker_limit"
    end
  end
end
