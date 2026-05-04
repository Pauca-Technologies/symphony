defmodule Mix.Tasks.Codex.Session.RenderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("codex.session.render")
    :ok
  end

  test "renders a transcript from disk" do
    path = Path.join(System.tmp_dir!(), "codex-session-render-#{System.unique_integer([:positive])}.ndjson")
    on_exit(fn -> File.rm(path) end)

    File.write!(
      path,
      Jason.encode!(%{
        "at" => "2026-04-23T12:00:00Z",
        "event" => "session_started",
        "session_id" => "thread-2-turn-2",
        "issue_identifier" => "TEST-2",
        "workspace_path" => "/tmp/workspace"
      })
    )

    output =
      capture_io(fn ->
        Mix.Tasks.Codex.Session.Render.run(["--no-color", path])
      end)

    assert output =~ "Session: thread-2-turn-2"
    assert output =~ "Issue: TEST-2"
  end

  test "raises with usage when no path is provided" do
    assert_raise Mix.Error, ~r/Usage: mix codex\.session\.render/, fn ->
      Mix.Tasks.Codex.Session.Render.run([])
    end
  end
end
