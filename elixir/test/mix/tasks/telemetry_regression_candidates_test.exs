defmodule Mix.Tasks.Telemetry.RegressionCandidatesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Telemetry.RegressionCandidates
  alias SymphonyElixir.RegressionCorpus

  @through ~D[2026-09-03]
  @run "018f4f95-c477-7a3f-9a54-111111111111"
  @sha String.duplicate("a", 64)
  @sha_b String.duplicate("b", 64)

  setup do
    root = Path.join(System.tmp_dir!(), "regression-candidates-task-#{System.unique_integer([:positive])}")
    telemetry = Path.join(root, "telemetry")
    staging = Path.join(root, "staging")
    File.mkdir_p!(telemetry)
    previous = Application.get_env(:symphony_elixir, :telemetry_dir)
    Application.put_env(:symphony_elixir, :telemetry_dir, telemetry)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: Application.put_env(:symphony_elixir, :telemetry_dir, previous),
        else: Application.delete_env(:symphony_elixir, :telemetry_dir)
    end)

    %{root: root, telemetry: telemetry, staging: staging}
  end

  test "default human dry-run prints only fixed candidate metadata and writes nothing", %{telemetry: telemetry} do
    poison = "BEGIN PROMPT\nBearer raw-secret\nraw tool output"
    write_events(telemetry, @through, poison)
    before = File.ls!(telemetry)

    output = run_task(["--through", "2026-09-03"])

    assert output =~ "Regression candidates: 1 pending review"
    assert output =~ "7 days, 2026-08-28 through 2026-09-03"
    assert output =~ "files=60 rows=50000 source_bytes=268435456"
    assert output =~ "selection: first_failure=response_timeout_or_stall"

    assert output =~
             "reproduction fields: backend,config_digest,model,prompt_sha256,reasoning_effort," <>
               "task_family"

    assert output =~ "evidence refs: telemetry:v1:"
    assert output =~ "Dry run: no files written."
    assert output =~ "mkdir -m 700 /absolute/staging-dir"
    refute output =~ poison
    refute output =~ "raw-secret"
    assert File.ls!(telemetry) == before
  end

  test "default telemetry root and UTC today select the current daily file", %{telemetry: telemetry} do
    write_events(telemetry, Date.utc_today(), "excluded")
    output = run_task([])
    assert output =~ "Regression candidates: 1 pending review"
    assert output =~ "through #{Date.utc_today()}"
  end

  test "offline scan does not start the Symphony application", %{telemetry: telemetry} do
    write_events(telemetry, @through, "excluded")

    script = """
    Application.put_env(:symphony_elixir, :telemetry_dir, #{inspect(telemetry)})
    Mix.Task.run("telemetry.regression_candidates", ["--through", "2026-09-03"])
    IO.puts("symphony_started=\#{inspect(Application.started_applications() |> Enum.any?(&(elem(&1, 0) == :symphony_elixir)))}")
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}, {"ERL_FLAGS", "+S 2:2"}],
        stderr_to_stdout: true
      )

    assert status == 0
    assert output =~ "Regression candidates: 1 pending review"
    assert output =~ "symphony_started=false"
  end

  test "JSON renders the pending corpus and bounded diagnostics without export", %{telemetry: telemetry} do
    write_events(telemetry, @through, "excluded")

    output =
      run_task([
        "--days",
        "30",
        "--through",
        "2026-09-03",
        "--telemetry-root",
        telemetry,
        "--json"
      ])

    assert {:ok, result} = Jason.decode(String.trim(output))
    assert result["corpus"]["state"] == "pending_review"
    assert result["corpus"]["window_days"] == 30
    assert result["diagnostics"]["files_selected"] == 1
    assert result["diagnostics"]["window_days"] == 30
    refute output =~ "excluded"
    assert ["2026-09-03.jsonl"] = File.ls!(telemetry)
  end

  test "export is explicit, private, pending-only, and idempotent", %{telemetry: telemetry, staging: staging} do
    write_events(telemetry, @through, "excluded")
    File.mkdir_p!(staging)
    File.chmod!(staging, 0o700)

    args = ["--through", "2026-09-03", "--telemetry-root", telemetry, "--export", staging]
    assert run_task(args) =~ "written in the private staging directory"
    assert [filename] = File.ls!(staging)
    assert String.ends_with?(filename, ".pending.json")
    assert File.stat!(Path.join(staging, filename)).mode |> Bitwise.band(0o777) == 0o600
    assert run_task(args) =~ "unchanged in the private staging directory"
  end

  test "verification rejects generated pending corpora and accepts externally reviewed fixtures", %{
    telemetry: telemetry,
    staging: staging
  } do
    write_events(telemetry, @through, "excluded")
    File.mkdir_p!(staging)
    File.chmod!(staging, 0o700)
    {:ok, %{corpus: pending}} = RegressionCorpus.scan(telemetry, @through)
    {:ok, %{path: pending_path}} = RegressionCorpus.export(pending, staging)

    assert_raise Mix.Error, ~r/accepted_corpus_required/, fn ->
      run_task(["--verify", pending_path])
    end

    accepted = accept(pending)
    accepted_path = Path.join(staging, "#{accepted["corpus_id"]}.json")
    File.write!(accepted_path, Jason.encode!(accepted))
    File.chmod!(accepted_path, 0o600)

    output = run_task(["--verify", accepted_path])
    assert output =~ "Accepted regression corpus verified: #{accepted["corpus_id"]}"
    assert output =~ "1 candidates, 1 reviewed assertions"
  end

  test "verification fails safely for an unavailable corpus" do
    missing = Path.join(System.tmp_dir!(), "rgc-corpus-#{String.duplicate("f", 32)}.json")

    assert_raise Mix.Error, ~r/could not be read safely/, fn ->
      run_task(["--verify", missing])
    end
  end

  test "human diagnostics report fixed omission codes", %{root: root} do
    unavailable = Path.join(root, "missing-telemetry")
    output = run_task(["--telemetry-root", unavailable, "--through", "2026-09-03"])
    assert output =~ "omissions=source_unavailable=1"
  end

  test "export refuses different bytes at the deterministic filename", %{telemetry: telemetry, staging: staging} do
    write_events(telemetry, @through, "excluded")
    File.mkdir_p!(staging)
    File.chmod!(staging, 0o700)
    {:ok, %{corpus: corpus}} = RegressionCorpus.scan(telemetry, @through)
    conflict = Path.join(staging, "#{corpus["corpus_id"]}.pending.json")
    File.write!(conflict, "{}")
    File.chmod!(conflict, 0o600)

    assert_raise Mix.Error, ~r/different corpus already occupies/, fn ->
      run_task(["--through", "2026-09-03", "--export", staging])
    end
  end

  test "invalid and incompatible flags fail closed", %{telemetry: telemetry, staging: staging} do
    invalid = [
      ["--unknown"],
      ["argument"],
      ["--days", "8"],
      ["--through", "2026-9-3"],
      ["--telemetry-root", "relative"],
      ["--json", "--export", staging],
      ["--verify", "/tmp/corpus.json", "--days", "7"]
    ]

    Enum.each(invalid, fn args ->
      assert_raise Mix.Error, fn -> run_task(args) end
    end)

    write_events(telemetry, @through, "excluded")

    assert_raise Mix.Error, ~r/mkdir -m 700/, fn ->
      run_task(["--through", "2026-09-03", "--export", staging])
    end
  end

  defp run_task(args) do
    Mix.Task.reenable("telemetry.regression_candidates")
    capture_io(fn -> RegressionCandidates.run(args) end)
  end

  defp write_events(root, date, poison) do
    events = [manifest(poison), failure(poison)]
    body = Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"
    File.write!(Path.join(root, "#{date}.jsonl"), body)
  end

  defp manifest(poison) do
    %{
      "schema_version" => 1,
      "event" => "run_manifest",
      "manifest_version" => 1,
      "ts" => "2026-09-03T00:00:00Z",
      "run_id" => @run,
      "agent" => %{"backend" => "codex", "model" => "gpt-5.6-sol", "reasoning_effort" => "xhigh"},
      "task" => %{"type" => "concurrency_liveness"},
      "config_digest" => @sha_b,
      "prompt" => %{"template_sha256" => @sha, "body" => poison},
      "tool_args" => %{"token" => poison},
      "output" => poison
    }
  end

  defp failure(poison) do
    %{
      "schema_version" => 1,
      "event" => "failure",
      "ts" => "2026-09-03T00:00:01Z",
      "run_id" => @run,
      "failure_class" => "response_timeout_or_stall",
      "failure_reason" => poison,
      "session_transcript" => poison
    }
  end

  defp accept(corpus) do
    candidates =
      Enum.map(corpus["candidates"], fn candidate ->
        Map.put(candidate, "assertions", %{
          "authority" => "reviewed",
          "process" => candidate["proposed_assertions"]["process"],
          "task_outcome" => "human_review:failed"
        })
      end)

    corpus
    |> Map.put("state", "accepted")
    |> Map.put("candidates", candidates)
    |> Map.put("review", %{
      "status" => "approved",
      "method" => "human",
      "approval_ref" => "github:pr:7504",
      "reviewer_sha256" => String.duplicate("e", 64),
      "approved_at" => "2026-09-03T00:00:00Z"
    })
  end
end
