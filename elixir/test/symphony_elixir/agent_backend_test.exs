defmodule SymphonyElixir.AgentBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentBackend
  alias SymphonyElixir.Acp.Client, as: AcpClient
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config.Schema.Agent

  describe "resolve/1" do
    test "maps backend names to modules, defaulting unknown/nil to the Codex app-server" do
      assert AgentBackend.resolve("codex") == AppServer
      assert AgentBackend.resolve("acp") == AcpClient
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
    test "agent.backend defaults to codex and accepts codex/acp only" do
      assert %Agent{}.backend == "codex"

      assert Agent.changeset(%Agent{}, %{"backend" => "acp"}).valid?
      assert Agent.changeset(%Agent{}, %{"backend" => "codex"}).valid?
      refute Agent.changeset(%Agent{}, %{"backend" => "gemini"}).valid?
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

    test "both backends declare the AgentBackend behaviour" do
      for mod <- [AppServer, AcpClient] do
        assert AgentBackend in (mod.module_info(:attributes)[:behaviour] || [])
      end
    end
  end
end
