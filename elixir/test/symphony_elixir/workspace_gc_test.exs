defmodule SymphonyElixir.WorkspaceGcTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.WorkspaceGc

  defmodule FailingTracker do
    @moduledoc false
    def recently_terminal_issues(_), do: {:error, :missing_linear_team_id}
  end

  setup do
    # Use the memory tracker for a deterministic recently_terminal_issues
    # source. Each test seeds the list directly.
    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(), tracker_kind: "memory")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recently_terminal_issues)
    end)

    :ok
  end

  defp issue(identifier, opts \\ []) do
    %Issue{
      id: Keyword.get(opts, :id, "id-" <> identifier),
      identifier: identifier,
      state: Keyword.get(opts, :state, "Done"),
      labels: Keyword.get(opts, :labels, [])
    }
  end

  describe "run_pass/1" do
    test "removes a worktree for a terminal issue with an existing path" do
      tmp = make_tmp_dir!()
      worktree = Path.join(tmp, "UDPE-101")
      File.mkdir_p!(worktree)

      Application.put_env(
        :symphony_elixir,
        :memory_tracker_recently_terminal_issues,
        [issue("UDPE-101")]
      )

      removed = :ets.new(:gc_test_removed, [:public, :set])

      remove_fn = fn path ->
        :ets.insert(removed, {path, true})
        File.rm_rf!(path)
        :ok
      end

      summary =
        WorkspaceGc.run_pass(
          workspace_path_fn: fn _ -> worktree end,
          remove_fn: remove_fn
        )

      assert summary.scanned == 1
      assert summary.removed == 1
      assert summary.skipped == 0
      assert [{^worktree, true}] = :ets.tab2list(removed)
    end

    test "silently skips when the worktree path doesn't exist" do
      tmp = make_tmp_dir!()
      worktree = Path.join(tmp, "UDPE-missing")
      # Note: we intentionally do NOT create worktree on disk.

      Application.put_env(
        :symphony_elixir,
        :memory_tracker_recently_terminal_issues,
        [issue("UDPE-missing")]
      )

      remove_attempts = :ets.new(:gc_test_attempts, [:public, :set])

      remove_fn = fn _path ->
        :ets.insert(remove_attempts, {:attempted, true})
        :ok
      end

      summary =
        WorkspaceGc.run_pass(
          workspace_path_fn: fn _ -> worktree end,
          remove_fn: remove_fn
        )

      # `missing` is silent: it's not counted in scanned/removed/skipped.
      assert summary.scanned == 0
      assert summary.removed == 0
      assert summary.skipped == 0
      # The remove_fn must NOT have been called for a non-existent path.
      assert :ets.tab2list(remove_attempts) == []
    end

    test "records gc_skipped when git worktree remove fails (dirty worktree, etc.)" do
      tmp = make_tmp_dir!()
      worktree = Path.join(tmp, "UDPE-dirty")
      File.mkdir_p!(worktree)

      Application.put_env(
        :symphony_elixir,
        :memory_tracker_recently_terminal_issues,
        [issue("UDPE-dirty")]
      )

      remove_fn = fn _path ->
        {:error, {:worktree_remove_failed, 1, "fatal: worktree contains modified files"}}
      end

      summary =
        WorkspaceGc.run_pass(
          workspace_path_fn: fn _ -> worktree end,
          remove_fn: remove_fn
        )

      assert summary.scanned == 1
      assert summary.removed == 0
      assert summary.skipped == 1
      # The worktree is preserved on disk.
      assert File.exists?(worktree)
    end

    test "returns a zeroed summary when the tracker fetch fails" do
      summary = WorkspaceGc.run_pass(tracker: FailingTracker)

      assert summary.scanned == 0
      assert summary.removed == 0
      assert summary.skipped == 0
    end

    test "handles multiple issues independently (one removed, one skipped, one missing)" do
      tmp = make_tmp_dir!()
      ok_path = Path.join(tmp, "UDPE-ok")
      dirty_path = Path.join(tmp, "UDPE-dirty")
      missing_path = Path.join(tmp, "UDPE-missing")
      File.mkdir_p!(ok_path)
      File.mkdir_p!(dirty_path)

      Application.put_env(
        :symphony_elixir,
        :memory_tracker_recently_terminal_issues,
        [
          issue("UDPE-ok"),
          issue("UDPE-dirty"),
          issue("UDPE-missing")
        ]
      )

      path_for = fn identifier ->
        Path.join(tmp, identifier)
      end

      remove_fn = fn path ->
        cond do
          String.ends_with?(path, "UDPE-ok") ->
            File.rm_rf!(path)
            :ok

          String.ends_with?(path, "UDPE-dirty") ->
            {:error, {:worktree_remove_failed, 1, "dirty"}}

          true ->
            :ok
        end
      end

      summary =
        WorkspaceGc.run_pass(
          workspace_path_fn: path_for,
          remove_fn: remove_fn
        )

      # UDPE-missing is silent (path doesn't exist), so it isn't counted.
      assert summary.scanned == 2
      assert summary.removed == 1
      assert summary.skipped == 1
      refute File.exists?(ok_path)
      assert File.exists?(dirty_path)
    end
  end

  defp make_tmp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-gc-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
