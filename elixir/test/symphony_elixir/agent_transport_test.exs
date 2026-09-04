defmodule SymphonyElixir.AgentTransportTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTransport
  alias SymphonyElixir.Config
  alias SymphonyElixir.Workflow

  describe "with_pre_command/2" do
    test "prepends the snippet joined with && before the fragment" do
      assert AgentTransport.with_pre_command("opencode acp", ". ./env.env") ==
               ". ./env.env && opencode acp"

      assert AgentTransport.with_pre_command("exec codex app-server", "export FOO=bar") ==
               "export FOO=bar && exec codex app-server"
    end

    test "returns the fragment unchanged when there is no pre-command" do
      assert AgentTransport.with_pre_command("opencode acp", nil) == "opencode acp"
    end
  end

  describe "pre_command/0" do
    test "reads agent.pre_command, normalizing blank to nil" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_pre_command: ". .artifacts/session.env")
      assert AgentTransport.pre_command() == ". .artifacts/session.env"
      assert AgentTransport.with_pre_command("claude -p") == ". .artifacts/session.env && claude -p"
    end

    test "is nil when unset" do
      write_workflow_file!(Workflow.workflow_file_path(), [])
      assert is_nil(Config.settings!().agent.pre_command)
      assert AgentTransport.pre_command() == nil
      assert AgentTransport.with_pre_command("claude -p") == "claude -p"
    end
  end
end
