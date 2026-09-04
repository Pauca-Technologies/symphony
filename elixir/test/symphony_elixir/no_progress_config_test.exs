defmodule SymphonyElixir.NoProgressConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.NoProgress
  alias SymphonyElixir.Workflow

  test "defaults and clamps only the four shadow thresholds" do
    assert NoProgress.parse(%{}) == %{
             error_repeat_threshold: 3,
             success_repeat_threshold: 8,
             success_no_progress_turns: 2,
             max_fingerprints: 32
           }

    assert NoProgress.parse(%{
             agent: %{
               no_progress: %{
                 error_repeat_threshold: 1,
                 success_repeat_threshold: 10_001,
                 success_no_progress_turns: "invalid",
                 max_fingerprints: 0,
                 enabled: false,
                 interrupt: true
               }
             }
           }) == %{
             error_repeat_threshold: 2,
             success_repeat_threshold: 1_000,
             success_no_progress_turns: 2,
             max_fingerprints: 1
           }

    assert Config.no_progress_settings(nil) == NoProgress.parse(%{})
    assert Config.no_progress_settings(%{config: "malformed"}) == NoProgress.parse(%{})
    assert NoProgress.parse(%{"agent" => "malformed"}) == NoProgress.parse(%{})

    assert NoProgress.parse(%{agent: %{no_progress: %{max_fingerprints: 1_000}}}).max_fingerprints == 32
  end

  test "a fresh workflow load observes updated no-progress thresholds" do
    path = Path.join(System.tmp_dir!(), "no-progress-workflow-#{System.unique_integer([:positive])}.md")

    on_exit(fn -> File.rm(path) end)

    write_workflow(path, 4)
    assert {:ok, first} = Workflow.load(path)
    assert Config.no_progress_settings(first).error_repeat_threshold == 4

    write_workflow(path, 7)
    assert {:ok, reloaded} = Workflow.load(path)
    assert Config.no_progress_settings(reloaded).error_repeat_threshold == 7
  end

  defp write_workflow(path, threshold) do
    File.write!(
      path,
      """
      ---
      agent:
        no_progress:
          error_repeat_threshold: #{threshold}
          success_repeat_threshold: 12
          success_no_progress_turns: 3
          max_fingerprints: 20
      ---
      Work on the issue.
      """
    )
  end
end
