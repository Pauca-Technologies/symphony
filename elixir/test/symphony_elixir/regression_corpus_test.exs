defmodule SymphonyElixir.RegressionCorpusTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{RegressionCandidate, RegressionCorpus}

  @today ~D[2026-09-03]

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-regression-corpus-#{System.unique_integer([:positive])}")
    telemetry = Path.join(root, "telemetry")
    staging = Path.join(root, "staging")
    File.mkdir_p!(telemetry)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, telemetry: telemetry, staging: staging}
  end

  test "scans only exact 7-day daily regular files and tolerates legacy and malformed rows", %{telemetry: root} do
    current = [manifest(), failure(), legacy_failure()]
    write_jsonl(Path.join(root, "2026-09-03.jsonl"), current, ["not-json", "[]"])
    write_jsonl(Path.join(root, "2026-08-28.jsonl"), [failure("aaaaaaaa-bbbb")])
    write_jsonl(Path.join(root, "2026-08-27.jsonl"), [failure("cccccccc-dddd")])
    write_jsonl(Path.join(root, "not-a-date.jsonl"), [failure("eeeeeeee-ffff")])
    File.write!(Path.join(root, "2026-09-02.txt"), Jason.encode!(failure()))

    assert {:ok, %{corpus: corpus, diagnostics: diagnostics}} = RegressionCorpus.scan(root, @today)
    assert corpus["window_days"] == 7
    assert corpus["summary"]["input_events"] == 4
    assert length(corpus["candidates"]) == 3
    assert diagnostics["files_selected"] == 2
    assert diagnostics["files_read"] == 2
    assert diagnostics["rows_seen"] == 6
    assert diagnostics["rows_decoded"] == 4
    assert diagnostics["malformed_rows"] == 2
    assert diagnostics["omissions"] == %{}
    assert {:ok, _report} = RegressionCandidate.verify(corpus)
  end

  test "30-day scan reads gzip incrementally and ignores dates outside the exact window", %{telemetry: root} do
    gzip = Enum.map([manifest(), failure()], &(Jason.encode!(&1) <> "\n")) |> :zlib.gzip()
    File.write!(Path.join(root, "2026-08-05.jsonl.gz"), gzip)
    File.write!(Path.join(root, "2026-08-04.jsonl.gz"), gzip)

    assert {:ok, %{corpus: corpus, diagnostics: diagnostics}} =
             RegressionCorpus.scan(root, @today, window_days: 30)

    assert corpus["window_days"] == 30
    assert length(corpus["candidates"]) == 1
    assert diagnostics["files_selected"] == 1
    assert diagnostics["rows_decoded"] == 2
    assert diagnostics["expanded_bytes"] > diagnostics["source_bytes"]
  end

  test "an active plain file wins over a gzip file for the same date", %{telemetry: root} do
    write_jsonl(Path.join(root, "2026-09-03.jsonl"), [%{failure() | "failure_class" => "transient_infrastructure"}])
    gzip = Jason.encode!(%{failure() | "failure_class" => "agent_protocol_failure"}) <> "\n"
    File.write!(Path.join(root, "2026-09-03.jsonl.gz"), :zlib.gzip(gzip))

    assert {:ok, %{corpus: corpus, diagnostics: diagnostics}} = RegressionCorpus.scan(root, @today)
    assert diagnostics["files_selected"] == 1
    assert [candidate] = corpus["candidates"]
    assert candidate["cluster"]["first_failure_class"] == "transient_infrastructure"
  end

  test "row and overlong-line bounds stop decoding before untrusted content", %{telemetry: root} do
    poison = String.duplicate("x", 16_385) <> "BEGIN_PROMPT"
    rows = List.duplicate("{}\n", 50_000)
    File.write!(Path.join(root, "2026-09-03.jsonl"), Enum.join(rows) <> poison <> "\n")

    assert {:ok, %{corpus: corpus, diagnostics: diagnostics}} = RegressionCorpus.scan(root, @today)
    assert diagnostics["overlong_lines"] == 0
    assert diagnostics["rows_seen"] == 50_000
    assert diagnostics["rows_decoded"] == 50_000
    assert diagnostics["omissions"] == %{"row_limit_reached" => 1}
    refute Jason.encode!(corpus) =~ "BEGIN_PROMPT"
  end

  test "overlong streamed lines are dropped and a final unterminated JSON row is decoded", %{telemetry: root} do
    payload = String.duplicate("{", 40_000) <> "\n" <> Jason.encode!(failure())
    File.write!(Path.join(root, "2026-09-03.jsonl"), payload)

    assert {:ok, %{corpus: corpus, diagnostics: diagnostics}} = RegressionCorpus.scan(root, @today)
    assert diagnostics["overlong_lines"] == 1
    assert diagnostics["rows_seen"] == 2
    assert diagnostics["rows_decoded"] == 1
    assert length(corpus["candidates"]) == 1
  end

  test "an overlong unterminated row is discarded at EOF", %{telemetry: root} do
    File.write!(Path.join(root, "2026-09-03.jsonl"), String.duplicate("{", 20_000))

    assert {:ok, %{diagnostics: diagnostics}} = RegressionCorpus.scan(root, @today)
    assert diagnostics["overlong_lines"] == 1
    assert diagnostics["rows_seen"] == 1
    assert diagnostics["rows_decoded"] == 0
  end

  test "gzip row caps stop a partially consumed stream safely", %{telemetry: root} do
    gzip = List.duplicate("{}\n", 50_001) |> :zlib.gzip()
    File.write!(Path.join(root, "2026-09-03.jsonl.gz"), gzip)

    assert {:ok, %{diagnostics: diagnostics}} = RegressionCorpus.scan(root, @today)
    assert diagnostics["rows_seen"] == 50_000
    assert diagnostics["rows_decoded"] == 50_000
    assert diagnostics["omissions"] == %{"row_limit_reached" => 1}
  end

  test "compressed expansion bombs are bounded and halt the window", %{telemetry: root} do
    bomb = :binary.copy("x", 32 * 1_024 * 1_024 + 1) |> :zlib.gzip()
    File.write!(Path.join(root, "2026-09-03.jsonl.gz"), bomb)
    write_jsonl(Path.join(root, "2026-09-02.jsonl"), [failure()])

    assert {:ok, %{corpus: corpus, diagnostics: diagnostics}} =
             RegressionCorpus.scan(root, @today, expanded_byte_limit: 32 * 1_024 * 1_024)

    assert corpus["candidates"] == []
    assert diagnostics["expanded_bytes"] <= 32 * 1_024 * 1_024
    assert diagnostics["omissions"]["expanded_bytes_exceeded"] == 1
    assert diagnostics["files_read"] == 1
  end

  test "corrupt and truncated gzip files are ignored with bounded diagnostics", %{telemetry: root} do
    File.write!(Path.join(root, "2026-09-03.jsonl.gz"), <<1, 2, 3, 4>>)
    truncated = :zlib.gzip("{}\n") |> binary_part(0, 5)
    File.write!(Path.join(root, "2026-09-02.jsonl.gz"), truncated)

    assert {:ok, %{corpus: corpus, diagnostics: diagnostics}} = RegressionCorpus.scan(root, @today)
    assert corpus["candidates"] == []
    assert diagnostics["omissions"] == %{"invalid_gzip" => 2}
  end

  test "compressed source bytes are capped independently of expanded bytes", %{telemetry: root} do
    incompressible = :crypto.strong_rand_bytes(17 * 1_024 * 1_024) |> Base.encode64() |> :zlib.gzip()
    File.write!(Path.join(root, "2026-09-03.jsonl.gz"), incompressible)

    assert {:ok, %{diagnostics: diagnostics}} =
             RegressionCorpus.scan(root, @today, source_byte_limit: 16 * 1_024 * 1_024)

    assert diagnostics["source_bytes"] <= 16 * 1_024 * 1_024
    assert diagnostics["omissions"]["source_bytes_exceeded"] == 1
  end

  test "default cap admits compact daily files over 16 MiB while symlinks remain unsafe", %{root: temp, telemetry: root} do
    large = Path.join(root, "2026-09-03.jsonl")
    File.write!(large, Jason.encode!(failure()) <> "\n" <> :binary.copy("x", 17 * 1_024 * 1_024))
    target = Path.join(root, "target.jsonl")
    File.write!(target, Jason.encode!(failure()))
    File.ln_s!(target, Path.join(root, "2026-09-02.jsonl"))

    assert {:ok, %{corpus: corpus, diagnostics: diagnostics}} = RegressionCorpus.scan(root, @today)
    assert length(corpus["candidates"]) == 1
    assert diagnostics["source_bytes"] > 16 * 1_024 * 1_024
    assert diagnostics["omissions"]["unsafe_or_unreadable_file"] == 1

    missing = Path.join(temp, "missing")

    assert {:ok, %{corpus: %{"candidates" => []}, diagnostics: missing_diagnostics}} =
             RegressionCorpus.scan(missing, @today)

    assert missing_diagnostics["omissions"] == %{"source_unavailable" => 1}
    assert {:error, :invalid_scan} = RegressionCorpus.scan("relative", @today)
    assert {:error, :invalid_scan} = RegressionCorpus.scan(root, "today")
    assert {:error, :invalid_window} = RegressionCorpus.scan(root, @today, window_days: 8)
    assert {:error, :invalid_scan} = RegressionCorpus.scan(root, @today, [{:window_days}])
  end

  test "plain source cap preserves complete rows and halts older-file scanning", %{telemetry: root} do
    payload = List.duplicate(Jason.encode!(failure()) <> "\n", 100) |> Enum.join()
    File.write!(Path.join(root, "2026-09-03.jsonl"), payload)
    write_jsonl(Path.join(root, "2026-09-02.jsonl"), [failure("aaaaaaaa-bbbb")])

    assert {:ok, %{corpus: corpus, diagnostics: diagnostics}} =
             RegressionCorpus.scan(root, @today, source_byte_limit: 8_192)

    assert length(corpus["candidates"]) == 1
    assert diagnostics["files_read"] == 1
    assert diagnostics["rows_decoded"] > 0
    assert diagnostics["omissions"] == %{"source_bytes_exceeded" => 1}
  end

  test "plain expanded cap preserves complete rows", %{telemetry: root} do
    payload = List.duplicate(Jason.encode!(failure()) <> "\n", 100) |> Enum.join()
    File.write!(Path.join(root, "2026-09-03.jsonl"), payload)

    assert {:ok, %{corpus: corpus, diagnostics: diagnostics}} =
             RegressionCorpus.scan(root, @today, expanded_byte_limit: 8_192)

    assert length(corpus["candidates"]) == 1
    assert diagnostics["rows_decoded"] > 0
    assert diagnostics["omissions"] == %{"expanded_bytes_exceeded" => 1}
  end

  test "gzip expanded cap preserves complete rows and halts older-file scanning", %{telemetry: root} do
    payload = List.duplicate(Jason.encode!(failure()) <> "\n", 200) |> Enum.join()
    File.write!(Path.join(root, "2026-09-03.jsonl.gz"), :zlib.gzip(payload))
    write_jsonl(Path.join(root, "2026-09-02.jsonl"), [failure("aaaaaaaa-bbbb")])

    assert {:ok, %{corpus: corpus, diagnostics: diagnostics}} =
             RegressionCorpus.scan(root, @today, expanded_byte_limit: 16_384)

    assert length(corpus["candidates"]) == 1
    assert diagnostics["files_read"] == 1
    assert diagnostics["rows_decoded"] > 0
    assert diagnostics["omissions"] == %{"expanded_bytes_exceeded" => 1}
  end

  test "exports pending corpus atomically with mode 0600 and returns unchanged idempotently", %{
    telemetry: root,
    staging: staging
  } do
    write_jsonl(Path.join(root, "2026-09-03.jsonl"), [manifest(), failure()])
    assert {:ok, %{corpus: corpus}} = RegressionCorpus.scan(root, @today)
    File.mkdir!(staging)
    File.chmod!(staging, 0o700)

    results =
      1..8
      |> Task.async_stream(fn _ -> RegressionCorpus.export(corpus, staging) end, max_concurrency: 8)
      |> Enum.map(fn {:ok, result} -> result end)

    assert 1 == Enum.count(results, &match?({:ok, %{status: :written}}, &1))
    assert 7 == Enum.count(results, &match?({:ok, %{status: :unchanged}}, &1))
    assert {:ok, %{status: :unchanged, path: path, corpus_id: id, bytes: bytes}} = RegressionCorpus.export(corpus, staging)

    assert Path.basename(path) == "#{id}.pending.json"
    assert bytes == File.stat!(path).size
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(staging).mode, 0o777) == 0o700
    assert {:ok, %{status: :unchanged, path: ^path}} = RegressionCorpus.export(corpus, staging)
    assert {:ok, ^corpus} = RegressionCorpus.read(path)
  end

  test "export rejects accepted, relative, source-tree, symlinked, and conflicting destinations", %{
    telemetry: root,
    staging: staging
  } do
    write_jsonl(Path.join(root, "2026-09-03.jsonl"), [failure()])
    assert {:ok, %{corpus: corpus}} = RegressionCorpus.scan(root, @today)
    accepted = %{corpus | "state" => "accepted"}
    invalid_id = %{corpus | "corpus_id" => "bad"}
    invalid_corpus = put_in(corpus, ["summary", "input_events"], 999)

    assert {:error, :invalid_export} = RegressionCorpus.export(accepted, staging)
    assert {:error, :invalid_export} = RegressionCorpus.export(invalid_id, staging)
    assert {:error, :invalid_export} = RegressionCorpus.export(invalid_corpus, staging)
    assert {:error, :invalid_export} = RegressionCorpus.export(:bad, staging)
    assert {:error, :invalid_export} = RegressionCorpus.export(corpus, "relative")
    assert {:error, :invalid_export} = RegressionCorpus.export(corpus, File.cwd!())
    assert {:error, :invalid_export} = RegressionCorpus.export(corpus, staging)

    File.mkdir_p!(staging)
    File.chmod!(staging, 0o700)
    path = Path.join(staging, "#{corpus["corpus_id"]}.pending.json")
    File.write!(path, "different")
    assert {:error, :conflicting_export} = RegressionCorpus.export(corpus, staging)

    File.rm!(path)
    File.ln_s!(root, path)
    assert {:error, :invalid_export} = RegressionCorpus.export(corpus, staging)

    unsafe_root = Path.join(Path.dirname(staging), "unsafe-root")
    File.write!(unsafe_root, "not-a-directory")
    assert {:error, :invalid_export} = RegressionCorpus.export(corpus, unsafe_root)

    public_root = Path.join(Path.dirname(staging), "public-root")
    File.mkdir!(public_root)
    File.chmod!(public_root, 0o755)
    assert {:error, :invalid_export} = RegressionCorpus.export(corpus, public_root)

    source_link = Path.join(Path.dirname(staging), "source-link")
    File.ln_s!(File.cwd!(), source_link)
    assert {:error, :invalid_export} = RegressionCorpus.export(corpus, Path.join(source_link, "test"))
  end

  test "bounded reads reject malformed, oversized, symlinked, and unsafe filenames", %{root: root} do
    malformed = Path.join(root, "rgc-corpus-#{String.duplicate("a", 32)}.json")
    File.write!(malformed, "{")
    assert {:error, :invalid_corpus_file} = RegressionCorpus.read(malformed)

    oversized = Path.join(root, "rgc-corpus-#{String.duplicate("b", 32)}.json")
    File.write!(oversized, :binary.copy("x", 1_048_577))
    assert {:error, :invalid_corpus_file} = RegressionCorpus.read(oversized)

    link = Path.join(root, "rgc-corpus-#{String.duplicate("c", 32)}.json")
    File.ln_s!(malformed, link)
    assert {:error, :invalid_corpus_file} = RegressionCorpus.read(link)
    assert {:error, :invalid_corpus_file} = RegressionCorpus.read(Path.join(root, "arbitrary.json"))
    assert {:error, :invalid_corpus_file} = RegressionCorpus.read(:not_a_path)
  end

  test "require_accepted rejects pending structural verification without echoing arbitrary options" do
    corpus = RegressionCandidate.build([failure()])

    assert {:error, %{errors: errors}} = RegressionCandidate.verify(corpus, require_accepted: true, mode: "raw-value")
    assert "accepted_corpus_required" in errors
    assert {:ok, report} = RegressionCandidate.verify(corpus, mode: "raw-value")
    assert report.state == "pending_review"
    refute Map.has_key?(report, :mode)
    refute inspect(report) =~ "raw-value"
  end

  defp write_jsonl(path, events, malformed \\ []) do
    payload = Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")) <> Enum.map_join(malformed, "", &(&1 <> "\n"))
    File.write!(path, payload)
  end

  defp manifest do
    %{
      "schema_version" => 1,
      "event" => "run_manifest",
      "ts" => "2026-09-03T00:00:00Z",
      "run_id" => "123e4567-e89b-12d3-a456-426614174000",
      "manifest_version" => 1,
      "agent" => %{"backend" => "codex", "model" => "gpt-5.6-sol", "reasoning_effort" => "xhigh"},
      "task" => %{"type" => "concurrency_liveness"},
      "config_digest" => String.duplicate("a", 64),
      "prompt" => %{"template_sha256" => String.duplicate("b", 64)}
    }
  end

  defp failure(run \\ "123e4567-e89b-12d3-a456-426614174000") do
    %{
      "schema_version" => 1,
      "event" => "failure",
      "ts" => "2026-09-03T00:00:01Z",
      "run_id" => run,
      "failure_class" => "response_timeout_or_stall"
    }
  end

  defp legacy_failure do
    %{
      "event" => "run_end",
      "ts" => "2026-09-03T00:00:02Z",
      "issue_identifier" => "LEGACY",
      "outcome" => "error"
    }
  end
end
