defmodule SymphonyElixir.Github.PrReviewSectionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Github.PrReviewSection

  describe "render/3" do
    test "wraps bounded legacy guidance in stable markers without displaying the effort tier" do
      block = PrReviewSection.render(:none, "Look at `lib/foo.ex`.")

      assert block =~ "<!-- symphony:review:start -->"
      assert block =~ "<!-- symphony:review:end -->"
      assert block =~ "## Review this PR"
      assert block =~ "Look at lib/foo.ex."
      refute block =~ "`lib/foo.ex`"
      refute block =~ "None"
    end

    test "renders structured exact-head targets and prominent video evidence" do
      block =
        PrReviewSection.render(
          :focused,
          %{
            "targets" => [
              %{
                "path" => "app/routes/example.tsx",
                "line_start" => 20,
                "line_end" => 24,
                "question" => "Does the write remain tenant scoped?"
              }
            ],
            "verification" => [
              %{
                "label" => "UI walkthrough video",
                "url" => "https://github.com/user-attachments/assets/video-id",
                "expectation" => "Confirm the compact and wide layouts."
              }
            ]
          },
          repository: "org/repo",
          head_oid: "abc123"
        )

      assert block =~ "**Review these**"

      assert block =~
               "[app/routes/example.tsx:20-24](https://github.com/org/repo/blob/abc123/app/routes/example.tsx#L20-L24)"

      assert block =~ "**Evidence / verification**"

      assert block =~
               "[UI walkthrough video](https://github.com/user-attachments/assets/video-id)"

      refute block =~ "Focused"
    end

    test "honors a custom heading" do
      assert PrReviewSection.render(:none, "x", section_heading: "## Reviewer notes") =~ "## Reviewer notes"
    end
  end

  describe "apply_to_body/2" do
    test "appends the block when no region is present" do
      block = PrReviewSection.render(:none, "a")
      assert {:changed, body} = PrReviewSection.apply_to_body("Existing body.", block)
      assert body =~ "Existing body."
      assert body =~ block
    end

    test "replaces an existing region in place (no duplication)" do
      first = PrReviewSection.render(:none, "a")
      {:changed, body} = PrReviewSection.apply_to_body("Top.", first)

      second = PrReviewSection.render(:thorough, "b")
      {:changed, body2} = PrReviewSection.apply_to_body(body, second)

      refute body2 =~ "\n\na\n"
      assert body2 =~ "\n\nb\n"
      assert length(Regex.scan(~r/symphony:review:start/, body2)) == 1
    end

    test "is a no-op when the region already matches" do
      block = PrReviewSection.render(:focused, "unchanged")
      {:changed, body} = PrReviewSection.apply_to_body("Top.", block)
      assert :unchanged = PrReviewSection.apply_to_body(body, block)
    end

    test "inserts new guidance immediately after the summary section" do
      body = "## What changed\n\n- concise change\n\n## Evidence\n\n- video"
      block = PrReviewSection.render(:focused, "Inspect the changed boundary.")

      assert {:changed, updated} = PrReviewSection.apply_to_body(body, block)
      assert updated =~ "- concise change\n\n#{block}\n\n## Evidence"
    end

    test "removes a stale managed section when no direction remains" do
      block = PrReviewSection.render(:focused, "Inspect this.")
      body = "## Summary\n\nChange.\n\n#{block}\n\n## Evidence\n\nVideo."

      assert {:changed, updated} = PrReviewSection.remove_from_body(body)
      refute updated =~ "symphony:review:start"
      assert updated =~ "## Evidence"
      assert :unchanged = PrReviewSection.remove_from_body(updated)
    end
  end

  describe "normalize_direction/1" do
    test "rejects unbounded or unsafe structured output" do
      assert {:error, {:too_many_review_targets, 4, 3}} =
               PrReviewSection.normalize_direction(%{
                 targets:
                   Enum.map(1..4, fn line ->
                     %{path: "app/example.ts", line_start: line, question: "Check this boundary."}
                   end)
               })

      assert {:error, :invalid_review_target_path} =
               PrReviewSection.normalize_direction(%{
                 targets: [%{path: "../secret", line_start: 1, question: "Check this boundary."}]
               })

      assert {:error, {:question, :too_long}} =
               PrReviewSection.normalize_direction(%{
                 targets: [
                   %{path: "app/example.ts", line_start: 1, question: String.duplicate("x", 241)}
                 ]
               })
    end

    test "flattens and caps legacy markdown during rollout" do
      legacy = "**Review policy**\n" <> String.duplicate("long guidance ", 40)
      assert {:ok, %{summary: summary}} = PrReviewSection.normalize_direction(legacy)
      refute summary =~ "\n"
      assert String.length(summary) == 280
    end
  end

  describe "resolve_pr/2" do
    test "parses number and body from gh pr view" do
      runner = fn ["pr", "view" | _], _cwd ->
        {Jason.encode!(%{
           "id" => "PR_9",
           "number" => 9,
           "body" => "B",
           "url" => "https://github.example/org/repo/pull/9",
           "headRefOid" => "abc123",
           "baseRefOid" => "base123",
           "baseRefName" => "main",
           "isDraft" => true,
           "changedFiles" => 4,
           "headRepository" => %{"nameWithOwner" => "org/repo"}
         }), 0}
      end

      assert {:ok,
              %{
                id: "PR_9",
                number: 9,
                body: "B",
                url: "https://github.example/org/repo/pull/9",
                head_oid: "abc123",
                base_oid: "base123",
                base_ref: "main",
                is_draft: true,
                changed_files: 4,
                repository: "org/repo"
              }} =
               PrReviewSection.resolve_pr("/tmp", pr_runner: runner)
    end

    test "passes an explicit PR URL to gh pr view before falling back to branch inference" do
      test_pid = self()

      runner = fn args, _cwd ->
        send(test_pid, {:args, args})
        {Jason.encode!(%{"id" => "PR_1358", "number" => 1358, "body" => "B"}), 0}
      end

      assert {:ok, %{id: "PR_1358", number: 1358, body: "B"}} =
               PrReviewSection.resolve_pr("/tmp",
                 pr_url: "https://github.com/Pauca-Technologies/udp-dashboard-v2/pull/1358",
                 pr_runner: runner
               )

      assert_received {:args,
                       [
                         "pr",
                         "view",
                         "https://github.com/Pauca-Technologies/udp-dashboard-v2/pull/1358",
                         "--json",
                         "id,number,body,url,headRefOid,baseRefOid,baseRefName,changedFiles,headRepository,isDraft"
                       ]}
    end

    test "ignores a blank explicit PR URL and falls back to current branch" do
      test_pid = self()

      runner = fn args, _cwd ->
        send(test_pid, {:args, args})
        {Jason.encode!(%{"id" => "PR_9", "number" => 9, "body" => "B"}), 0}
      end

      assert {:ok, %{id: "PR_9", number: 9, body: "B"}} =
               PrReviewSection.resolve_pr("/tmp", pr_url: "  ", pr_runner: runner)

      assert_received {:args,
                       [
                         "pr",
                         "view",
                         "--json",
                         "id,number,body,url,headRefOid,baseRefOid,baseRefName,changedFiles,headRepository,isDraft"
                       ]}
    end

    test "treats a null body as empty" do
      runner = fn _args, _cwd -> {Jason.encode!(%{"id" => "PR_9", "number" => 9, "body" => nil}), 0} end
      assert {:ok, %{id: "PR_9", number: 9, body: ""}} = PrReviewSection.resolve_pr("/tmp", pr_runner: runner)
    end

    test "accepts PR view output without a node id" do
      runner = fn _args, _cwd -> {Jason.encode!(%{"number" => 9, "body" => "B"}), 0} end
      assert {:ok, %{id: nil, number: 9, body: "B"}} = PrReviewSection.resolve_pr("/tmp", pr_runner: runner)
    end

    test "skips on a non-zero exit (no PR)" do
      runner = fn _args, _cwd -> {"no pull requests found", 1} end
      assert {:skip, :no_pr} = PrReviewSection.resolve_pr("/tmp", pr_runner: runner)
    end

    test "skips on unparseable output" do
      runner = fn _args, _cwd -> {"not json", 0} end
      assert {:skip, :pr_view_unparseable} = PrReviewSection.resolve_pr("/tmp", pr_runner: runner)
    end

    test "skips (does not raise) when gh is unavailable" do
      runner = fn _args, _cwd -> raise "executable not found" end
      assert {:skip, reason} = PrReviewSection.resolve_pr("/tmp", pr_runner: runner)
      assert reason =~ "executable not found"
    end
  end

  describe "managed draft lifecycle" do
    test "moves a ready PR to draft and verifies the exact head" do
      test_pid = self()

      runner = fn
        ["pr", "ready", "7", "--undo"], _cwd ->
          send(test_pid, :drafted)
          {"", 0}

        ["pr", "view", "7", "--json", _fields], _cwd ->
          {Jason.encode!(%{
             "id" => "PR_7",
             "number" => 7,
             "body" => "Body",
             "headRefOid" => "head-7",
             "isDraft" => true
           }), 0}
      end

      assert {:ok, %{is_draft: true, head_oid: "head-7"}} =
               PrReviewSection.ensure_draft(
                 "/tmp",
                 %{id: "PR_7", number: 7, body: "Body", head_oid: "head-7", is_draft: false},
                 pr_runner: runner
               )

      assert_received :drafted
    end

    test "marks an approved draft ready and rejects a changed head" do
      runner = fn
        ["pr", "ready", "7"], _cwd ->
          {"", 0}

        ["pr", "view", "7", "--json", _fields], _cwd ->
          {Jason.encode!(%{
             "id" => "PR_7",
             "number" => 7,
             "body" => "Body",
             "headRefOid" => "changed-head",
             "isDraft" => false
           }), 0}
      end

      assert {:error, {:pr_head_changed, "head-7", "changed-head"}} =
               PrReviewSection.mark_ready(
                 "/tmp",
                 %{id: "PR_7", number: 7, body: "Body", head_oid: "head-7", is_draft: true},
                 pr_runner: runner
               )
    end
  end

  describe "upsert/5" do
    test "writes the edited body via GitHub's updatePullRequest mutation" do
      test_pid = self()

      runner = fn
        ["api", "graphql" | _] = args, _cwd ->
          send(test_pid, {:edited, graphql_body_arg(args), args})
          {"", 0}
      end

      assert :written =
               PrReviewSection.upsert("/tmp", %{id: "PR_7", number: 7, body: "Body."}, :thorough, "watch out", pr_runner: runner)

      assert_received {:edited, body, args}
      assert "pullRequestId=PR_7" in args
      assert body =~ "Body."
      assert body =~ "watch out"
      refute body =~ "Thorough"
    end

    test "does not write when the section is unchanged" do
      block = PrReviewSection.render(:none, "hi")
      body = "Top.\n\n" <> block <> "\n"
      runner = fn _args, _cwd -> flunk("must not edit when unchanged") end

      assert :unchanged =
               PrReviewSection.upsert("/tmp", %{number: 7, body: body}, :none, "hi", pr_runner: runner)
    end

    test "removes an existing section when structured direction is empty" do
      block = PrReviewSection.render(:focused, "old guidance")
      body = "Top.\n\n#{block}\n"
      test_pid = self()

      runner = fn ["api", "graphql" | _] = args, _cwd ->
        send(test_pid, {:edited, graphql_body_arg(args)})
        {"", 0}
      end

      assert :written =
               PrReviewSection.upsert(
                 "/tmp",
                 %{id: "PR_7", number: 7, body: body},
                 :none,
                 %{targets: [], verification: []},
                 pr_runner: runner
               )

      assert_received {:edited, updated}
      refute updated =~ "symphony:review:start"
    end

    test "skips when there is no PR" do
      assert :skipped = PrReviewSection.upsert("/tmp", nil, :none, "x", [])
    end

    test "skips when gh api update fails" do
      runner = fn ["api", "graphql" | _], _cwd -> {"boom", 1} end
      assert :skipped = PrReviewSection.upsert("/tmp", %{id: "PR_7", number: 7, body: "b"}, :none, "x", pr_runner: runner)
    end

    test "skips (does not raise) when the gh api runner crashes" do
      runner = fn ["api", "graphql" | _], _cwd -> raise "gh exploded" end
      assert :skipped = PrReviewSection.upsert("/tmp", %{id: "PR_7", number: 7, body: "b"}, :none, "x", pr_runner: runner)
    end

    test "swallows and truncates non-binary gh output" do
      runner = fn ["api", "graphql" | _], _cwd -> {~c"charlist output", 1} end
      assert :skipped = PrReviewSection.upsert("/tmp", %{id: "PR_7", number: 7, body: "b"}, :none, "x", pr_runner: runner)
    end

    test "skips when the PR node id is missing" do
      runner = fn _args, _cwd -> flunk("must not update without a PR node id") end
      assert :skipped = PrReviewSection.upsert("/tmp", %{number: 7, body: "b"}, :none, "x", pr_runner: runner)
    end
  end

  describe "default runner" do
    test "shells out to gh found on PATH for view and update" do
      shim_dir = Path.join(System.tmp_dir!(), "gh-shim-#{System.unique_integer([:positive])}")
      File.mkdir_p!(shim_dir)
      gh = Path.join(shim_dir, "gh")

      File.write!(
        gh,
        "#!/bin/sh\nif [ \"$2\" = \"view\" ]; then echo '{\"id\":\"PR_1\",\"number\":1,\"body\":\"b\"}'; fi\nexit 0\n"
      )

      File.chmod!(gh, 0o755)

      original_path = System.get_env("PATH")

      on_exit(fn ->
        restore_path(original_path)
        File.rm_rf(shim_dir)
      end)

      System.put_env("PATH", shim_dir <> ":" <> (original_path || ""))

      # No :pr_runner opt -> exercises the default System.cmd-based runner.
      assert {:ok, %{number: 1, body: "b"} = pr} = PrReviewSection.resolve_pr(shim_dir)
      assert :written = PrReviewSection.upsert(shim_dir, pr, :none, "x", [])
    end
  end

  defp graphql_body_arg(args) do
    assert Enum.any?(args, &String.starts_with?(&1, "query="))
    assert Enum.any?(args, &String.contains?(&1, "updatePullRequest"))

    args
    |> Enum.find(&String.starts_with?(&1, "body="))
    |> String.replace_prefix("body=", "")
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end
