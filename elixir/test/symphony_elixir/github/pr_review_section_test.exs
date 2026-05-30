defmodule SymphonyElixir.Github.PrReviewSectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Github.PrReviewSection

  describe "render/3" do
    test "wraps heading, badge, and prose in stable markers" do
      block = PrReviewSection.render(:safe, "Look at `lib/foo.ex`.")

      assert block =~ "<!-- symphony:review:start -->"
      assert block =~ "<!-- symphony:review:end -->"
      assert block =~ "## 🤖 How to review this PR"
      assert block =~ "🟢 **Safe**"
      assert block =~ "Look at `lib/foo.ex`."
    end

    test "renders the badge from the risk enum" do
      assert PrReviewSection.render(:skim, "") =~ "🔵 **Skim**"
      assert PrReviewSection.render(:medium, "") =~ "🟠 **Medium risk**"
      assert PrReviewSection.render(:high, "") =~ "🔴 **High risk**"
    end

    test "falls back when the reviewer gave no prose" do
      assert PrReviewSection.render(:safe, "") =~ "did not provide written guidance"
      assert PrReviewSection.render(:safe, "   ") =~ "did not provide written guidance"
    end

    test "honors a custom heading" do
      assert PrReviewSection.render(:safe, "x", section_heading: "## Reviewer notes") =~ "## Reviewer notes"
    end
  end

  describe "apply_to_body/2" do
    test "appends the block when no region is present" do
      block = PrReviewSection.render(:safe, "a")
      assert {:changed, body} = PrReviewSection.apply_to_body("Existing body.", block)
      assert body =~ "Existing body."
      assert body =~ block
    end

    test "replaces an existing region in place (no duplication)" do
      first = PrReviewSection.render(:safe, "a")
      {:changed, body} = PrReviewSection.apply_to_body("Top.", first)

      second = PrReviewSection.render(:high, "b")
      {:changed, body2} = PrReviewSection.apply_to_body(body, second)

      refute body2 =~ "🟢 **Safe**"
      assert body2 =~ "🔴 **High risk**"
      assert length(Regex.scan(~r/symphony:review:start/, body2)) == 1
    end

    test "is a no-op when the region already matches" do
      block = PrReviewSection.render(:medium, "unchanged")
      {:changed, body} = PrReviewSection.apply_to_body("Top.", block)
      assert :unchanged = PrReviewSection.apply_to_body(body, block)
    end
  end

  describe "resolve_pr/2" do
    test "parses number and body from gh pr view" do
      runner = fn ["pr", "view" | _], _cwd -> {Jason.encode!(%{"number" => 9, "body" => "B"}), 0} end
      assert {:ok, %{number: 9, body: "B"}} = PrReviewSection.resolve_pr("/tmp", pr_runner: runner)
    end

    test "treats a null body as empty" do
      runner = fn _args, _cwd -> {Jason.encode!(%{"number" => 9, "body" => nil}), 0} end
      assert {:ok, %{number: 9, body: ""}} = PrReviewSection.resolve_pr("/tmp", pr_runner: runner)
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

  describe "upsert/5" do
    test "writes the edited body via gh pr edit" do
      test_pid = self()

      runner = fn
        ["pr", "edit", "7", "--body-file", path], _cwd ->
          send(test_pid, {:edited, File.read!(path)})
          {"", 0}
      end

      assert :written =
               PrReviewSection.upsert("/tmp", %{number: 7, body: "Body."}, :high, "watch out", pr_runner: runner)

      assert_received {:edited, body}
      assert body =~ "Body."
      assert body =~ "🔴 **High risk**"
      assert body =~ "watch out"
    end

    test "does not write when the section is unchanged" do
      block = PrReviewSection.render(:safe, "hi")
      body = "Top.\n\n" <> block <> "\n"
      runner = fn _args, _cwd -> flunk("must not edit when unchanged") end

      assert :unchanged =
               PrReviewSection.upsert("/tmp", %{number: 7, body: body}, :safe, "hi", pr_runner: runner)
    end

    test "skips when there is no PR" do
      assert :skipped = PrReviewSection.upsert("/tmp", nil, :safe, "x", [])
    end

    test "skips when gh edit fails" do
      runner = fn ["pr", "edit" | _], _cwd -> {"boom", 1} end
      assert :skipped = PrReviewSection.upsert("/tmp", %{number: 7, body: "b"}, :safe, "x", pr_runner: runner)
    end

    test "skips (does not raise) when the gh edit runner crashes" do
      runner = fn ["pr", "edit" | _], _cwd -> raise "gh exploded" end
      assert :skipped = PrReviewSection.upsert("/tmp", %{number: 7, body: "b"}, :safe, "x", pr_runner: runner)
    end

    test "swallows and truncates non-binary gh output" do
      runner = fn ["pr", "edit" | _], _cwd -> {~c"charlist output", 1} end
      assert :skipped = PrReviewSection.upsert("/tmp", %{number: 7, body: "b"}, :safe, "x", pr_runner: runner)
    end
  end

  describe "default runner" do
    test "shells out to gh found on PATH for view and edit" do
      shim_dir = Path.join(System.tmp_dir!(), "gh-shim-#{System.unique_integer([:positive])}")
      File.mkdir_p!(shim_dir)
      gh = Path.join(shim_dir, "gh")
      File.write!(gh, "#!/bin/sh\nif [ \"$2\" = \"view\" ]; then echo '{\"number\":1,\"body\":\"b\"}'; fi\nexit 0\n")
      File.chmod!(gh, 0o755)

      original_path = System.get_env("PATH")

      on_exit(fn ->
        restore_path(original_path)
        File.rm_rf(shim_dir)
      end)

      System.put_env("PATH", shim_dir <> ":" <> (original_path || ""))

      # No :pr_runner opt -> exercises the default System.cmd-based runner.
      assert {:ok, %{number: 1, body: "b"} = pr} = PrReviewSection.resolve_pr(shim_dir)
      assert :written = PrReviewSection.upsert(shim_dir, pr, :safe, "x", [])
    end
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end
