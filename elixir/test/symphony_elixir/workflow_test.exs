defmodule SymphonyElixir.WorkflowTest do
  use SymphonyElixir.TestSupport

  describe "workflow_file_path/0" do
    test "prefers the SYMPHONY_WORKFLOW_FILE env var when no app override is set" do
      previous_override = Application.get_env(:symphony_elixir, :workflow_file_path)
      previous_env = System.get_env("SYMPHONY_WORKFLOW_FILE")

      on_exit(fn ->
        if previous_override do
          Application.put_env(:symphony_elixir, :workflow_file_path, previous_override)
        else
          Application.delete_env(:symphony_elixir, :workflow_file_path)
        end

        restore_env("SYMPHONY_WORKFLOW_FILE", previous_env)
      end)

      Application.delete_env(:symphony_elixir, :workflow_file_path)
      System.put_env("SYMPHONY_WORKFLOW_FILE", "/tmp/symphony-custom-workflow.md")

      assert Workflow.workflow_file_path() == "/tmp/symphony-custom-workflow.md"
    end
  end
end
