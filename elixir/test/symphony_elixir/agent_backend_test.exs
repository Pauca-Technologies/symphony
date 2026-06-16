defmodule SymphonyElixir.AgentBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentBackend
  alias SymphonyElixir.Acp.Client, as: AcpClient
  alias SymphonyElixir.ClaudeCode.Client, as: ClaudeCodeClient
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config.Schema.Agent
  alias SymphonyElixir.Config.Schema.Agent.LabelPreset
  alias SymphonyElixir.Linear.Issue

  describe "resolve/1" do
    test "maps backend names to modules, defaulting unknown/nil to the Codex app-server" do
      assert AgentBackend.resolve("codex") == AppServer
      assert AgentBackend.resolve("acp") == AcpClient
      assert AgentBackend.resolve("claude_code") == ClaudeCodeClient
      assert AgentBackend.resolve("bogus") == AppServer
      assert AgentBackend.resolve(nil) == AppServer
    end
  end

  describe "resolve/0" do
    test "defaults to the Codex app-server backend" do
      assert AgentBackend.resolve() == AppServer
    end
  end

  describe "config selector" do
    test "agent.backend defaults to codex and accepts codex/acp/claude_code only" do
      assert %Agent{}.backend == "codex"

      assert Agent.changeset(%Agent{}, %{"backend" => "acp"}).valid?
      assert Agent.changeset(%Agent{}, %{"backend" => "codex"}).valid?
      assert Agent.changeset(%Agent{}, %{"backend" => "claude_code"}).valid?
      refute Agent.changeset(%Agent{}, %{"backend" => "gemini"}).valid?
    end
  end

  describe "resolve_for_labels/2 (per-task backend+model)" do
    defp preset_agent do
      %Agent{
        backend: "codex",
        label_presets: [
          %LabelPreset{label: "agent:fast", backend: "acp", model: "opencode/north-mini-code-free"},
          %LabelPreset{label: "agent:deep", backend: "claude_code", model: "opus"},
          %LabelPreset{label: "agent:codex", backend: "codex", model: "ignored"},
          %LabelPreset{label: "agent:acp-default", backend: "acp"}
        ]
      }
    end

    test "a matching label picks that preset's backend and model override" do
      assert {AcpClient, %{model: "opencode/north-mini-code-free"}} =
               AgentBackend.resolve_for_labels(preset_agent(), ["agent:fast"])

      assert {ClaudeCodeClient, %{model: "opus"}} =
               AgentBackend.resolve_for_labels(preset_agent(), ["agent:deep"])
    end

    test "precedence is positional (list order), not label order on the issue" do
      # Both labels match; the first preset in list order ("agent:fast") wins.
      assert {AcpClient, %{model: "opencode/north-mini-code-free"}} =
               AgentBackend.resolve_for_labels(preset_agent(), ["agent:deep", "agent:fast"])
    end

    test "a codex preset ignores any model (Codex has no per-task model)" do
      assert {AppServer, %{}} = AgentBackend.resolve_for_labels(preset_agent(), ["agent:codex"])
    end

    test "a preset without a model yields empty overrides" do
      assert {AcpClient, %{}} = AgentBackend.resolve_for_labels(preset_agent(), ["agent:acp-default"])
    end

    test "no matching label falls through to the default backend with empty overrides" do
      assert {AppServer, %{}} = AgentBackend.resolve_for_labels(preset_agent(), ["unrelated"])
      assert {AppServer, %{}} = AgentBackend.resolve_for_labels(preset_agent(), [])
    end

    test "no label_presets resolves identically to {resolve/0, %{}} (default-path guard)" do
      assert {AppServer, %{}} = AgentBackend.resolve_for_labels(%Agent{}, ["whatever"])
    end
  end

  describe "resolve_for_issue/1" do
    test "reads labels off an Issue struct and delegates to config (default → codex)" do
      issue = %Issue{identifier: "ENG-1", labels: ["agent:fast"]}
      assert {AppServer, %{}} = AgentBackend.resolve_for_issue(issue)
    end

    test "tolerates a nil issue" do
      assert {AppServer, %{}} = AgentBackend.resolve_for_issue(nil)
    end
  end

  describe "Acp.Client conforms to the behaviour" do
    test "start_session validates the workspace cwd like the Codex path" do
      assert {:error, {:invalid_workspace_cwd, _kind, _path, _root}} =
               AcpClient.start_session("/definitely/outside/workspace/root", worker_host: nil)
    end

    test "stop_session tolerates a non-session map" do
      assert AcpClient.stop_session(%{}) == :ok
    end

    test "all backends declare the AgentBackend behaviour" do
      for mod <- [AppServer, AcpClient, ClaudeCodeClient] do
        assert AgentBackend in (mod.module_info(:attributes)[:behaviour] || [])
      end
    end
  end
end
