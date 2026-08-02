defmodule SymphonyElixir.ReviewPacket do
  @moduledoc """
  Builds the bounded, versioned evidence packet used by fresh review threads.

  Packet compaction is deterministic and deliberately asymmetric: prose and
  already-reproducible evidence are compacted before manifests and findings.
  Candidate identity, authoritative full-diff instructions, security rule
  references, requested lenses, and the review budgets are never removed.
  """

  alias SymphonyElixir.{Linear.Issue, PathSafety, ReviewOutcome}

  @schema_version 1
  @archive_dir ".artifacts/symphony-review/packets"
  @text_limit 8_000
  @compact_text_limit 1_200
  @context_bytes_per_token 3
  @review_prompt_reserve_bytes 10_000
  @delta_stat_limit 2_000
  @security_terms ~w(auth authorization authz tenant security permission access secret injection)

  @type packet :: map()
  @type build_result :: %{
          packet: packet(),
          encoded: String.t(),
          path: Path.t(),
          archive_path: Path.t()
        }

  @doc "Build and persist an exact-candidate review packet."
  @spec build(Path.t(), Issue.t(), map() | nil, String.t() | nil, ReviewOutcome.t() | nil, map(), keyword()) ::
          {:ok, build_result()} | {:error, term()}
  def build(workspace, %Issue{} = issue, pr, head_sha, prior_outcome, settings, opts \\ [])
      when is_binary(workspace) and is_map(settings) do
    git_runner = Keyword.get(opts, :git_runner, &default_git_runner/2)
    base = resolve_base(workspace, pr, git_runner)
    repository = repository_identity(workspace, pr, git_runner)
    diff = diff_evidence(workspace, base.sha, head_sha, pr, git_runner)
    attestations = load_attestations(workspace, head_sha, opts)
    prior = prior_review(prior_outcome, base.sha, head_sha, workspace, git_runner)
    changed_files = diff.changed_files
    rules = relevant_rules(workspace, changed_files)
    risk = risk_classification(changed_files, prior_outcome, opts)

    packet = %{
      schema_version: @schema_version,
      packet_id: nil,
      candidate: %{
        repository: repository,
        pull_request: pull_request_identity(pr),
        base_ref: base.ref,
        base_sha: base.sha,
        head_sha: head_sha,
        fingerprint: diff.fingerprint
      },
      issue: issue_contract(issue),
      diff: %{
        mode: review_mode(risk, prior),
        manifest: diff.manifest,
        diff_stat: diff.stat,
        authoritative_full_diff: authoritative_diff_instructions(base, head_sha, pr),
        missing_artifacts: diff.missing_artifacts
      },
      repository_rules: rules,
      risk: risk,
      requested_lenses: requested_lenses(risk, changed_files, opts),
      validation_attestations: attestations.entries,
      unresolved_findings: prior.findings,
      follow_up: prior.delta,
      implementation: implementation_context(issue, pr, diff, risk, attestations, opts),
      budgets: %{
        packet_max_bytes: settings.packet_max_bytes,
        context_budget_tokens: settings.context_budget_tokens,
        turn_budget: settings.turn_budget,
        tool_output_max_bytes: settings.tool_output_max_bytes,
        candidate_reduction_allowed: false
      },
      evidence_status: %{
        missing_artifacts: Enum.uniq(diff.missing_artifacts ++ attestations.missing),
        skipped_proof: attestations.skipped,
        authoritative_candidate_available: present?(head_sha),
        prior_review_sha: prior.reviewed_sha
      },
      compaction: %{
        priority_order: [
          "candidate_and_full_diff_access",
          "security_tenant_auth_rules",
          "issue_acceptance_and_non_goals",
          "risk_and_lens_rationale",
          "manifest_and_open_findings",
          "attestations",
          "implementation_and_evidence_prose"
        ],
        compacted_fields: []
      }
    }

    raw_evidence = %{
      candidate: packet.candidate,
      diff_manifest: diff.manifest,
      validation_attestations: attestations.entries,
      unresolved_findings: prior.findings
    }

    evidence_encoded = Jason.encode!(raw_evidence, pretty: true)
    evidence_id = sha256(evidence_encoded)
    evidence_relative_path = Path.join([@archive_dir, "evidence", "#{evidence_id}.json"])

    packet =
      packet
      |> put_in([:evidence_status, :raw_evidence_artifact], evidence_relative_path)
      |> update_in([:implementation, :evidence_links], fn links ->
        Enum.uniq(links ++ [evidence_relative_path])
      end)

    max_bytes = effective_max_bytes(settings)
    packet = packet |> compact_to(max_bytes) |> assign_packet_id()
    encoded = Jason.encode!(packet, pretty: true)

    if byte_size(encoded) <= max_bytes do
      persist_packet(
        workspace,
        settings.packet_path,
        packet.packet_id,
        encoded,
        evidence_relative_path,
        evidence_encoded
      )
      |> case do
        {:ok, paths} -> {:ok, Map.merge(paths, %{packet: packet, encoded: encoded})}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:packet_bound_unachievable, byte_size(encoded), max_bytes}}
    end
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  end

  @doc "Return the schema version understood by this Symphony build."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  defp effective_max_bytes(settings) do
    # Match ReviewGate's conservative three-byte/token whole-prompt ceiling and
    # reserve deterministic space for the repository workflow plus guards.
    min(
      settings.packet_max_bytes,
      max(
        settings.context_budget_tokens * @context_bytes_per_token -
          @review_prompt_reserve_bytes,
        8_192
      )
    )
  end

  defp assign_packet_id(packet) do
    identity =
      packet
      |> put_in([:packet_id], nil)
      |> Jason.encode!()
      |> sha256()

    %{packet | packet_id: "review-packet-v#{@schema_version}-#{identity}"}
  end

  defp persist_packet(
         workspace,
         configured_path,
         packet_id,
         encoded,
         evidence_relative_path,
         evidence_encoded
       ) do
    with {:ok, path} <- workspace_path(workspace, configured_path),
         {:ok, archive_path} <- workspace_path(workspace, Path.join(@archive_dir, "#{packet_id}.json")),
         {:ok, evidence_path} <- workspace_path(workspace, evidence_relative_path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.mkdir_p(Path.dirname(archive_path)),
         :ok <- File.mkdir_p(Path.dirname(evidence_path)),
         :ok <- File.write(evidence_path, evidence_encoded),
         :ok <- File.write(archive_path, encoded),
         :ok <- File.write(path, encoded) do
      {:ok, %{path: path, archive_path: archive_path, evidence_path: evidence_path}}
    end
  end

  defp workspace_path(workspace, relative_path) do
    expanded_workspace = Path.expand(workspace)
    expanded_path = Path.expand(relative_path, expanded_workspace)

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_path} <- PathSafety.canonicalize(expanded_path) do
      if canonical_path == canonical_workspace or
           String.starts_with?(canonical_path, canonical_workspace <> "/") do
        {:ok, canonical_path}
      else
        {:error, {:packet_path_outside_workspace, relative_path}}
      end
    end
  end

  # Lowest-priority, reproducible prose is compacted first. Each stage records
  # exactly what changed; the final emergency representation still retains all
  # required contract keys and raw-diff/rule access paths.
  defp compact_to(packet, max_bytes) do
    stages = [
      {"implementation_and_evidence_prose", &compact_implementation/1},
      {"attestation_detail", &compact_attestations/1},
      {"manifest_entries", &compact_manifest/1},
      {"finding_bodies", &compact_findings/1},
      {"repository_rule_excerpts", &compact_rule_excerpts/1},
      {"issue_prose", &compact_issue/1},
      {"minimal_bounded_representation", &minimal_packet/1}
    ]

    Enum.reduce_while(stages, packet, fn {name, compact}, current ->
      if encoded_size(current) <= max_bytes do
        {:halt, current}
      else
        {:cont, current |> compact.() |> mark_compacted(name)}
      end
    end)
  end

  defp compact_implementation(packet) do
    packet
    |> update_in([:implementation, :summary], &truncate(&1, @compact_text_limit))
    |> update_in([:implementation, :known_risks], &take_and_count(&1, 12))
    |> update_in([:implementation, :evidence_links], &take_and_count(&1, 12))
  end

  defp compact_attestations(packet) do
    update_in(packet, [:validation_attestations], fn entries ->
      entries
      |> Enum.take(20)
      |> Enum.map(&Map.take(&1, [:command, :head_sha, :status, :duration_ms, :environment, :harness_version, :artifact_refs]))
    end)
  end

  defp compact_manifest(packet) do
    update_in(packet, [:diff, :manifest], fn manifest ->
      %{entries: Enum.take(manifest.entries, 120), total_files: manifest.total_files, omitted_files: max(manifest.total_files - 120, 0)}
    end)
  end

  defp compact_findings(packet) do
    update_in(packet, [:unresolved_findings], fn findings ->
      findings
      |> Enum.take(40)
      |> Enum.map(fn finding -> Map.update(finding, :body, "", &truncate(&1, 600)) end)
    end)
  end

  defp compact_rule_excerpts(packet) do
    update_in(packet, [:repository_rules], fn rules ->
      Enum.map(rules, fn rule ->
        rule
        |> Map.update(:area_excerpt, "", &truncate(&1, 800))
        |> Map.put(:full_rule_instruction, "Read the complete file at #{rule.path} before judging affected paths.")
      end)
    end)
  end

  defp compact_issue(packet) do
    update_in(packet, [:issue], fn issue ->
      issue
      |> Map.update!(:requested_outcome, &truncate(&1, 1_000))
      |> Map.update!(:acceptance_criteria, &truncate(&1, 1_500))
      |> Map.update!(:non_goals, &truncate(&1, 800))
    end)
  end

  defp minimal_packet(packet) do
    %{
      packet
      | validation_attestations: Enum.map(packet.validation_attestations, &Map.take(&1, [:command, :head_sha, :status, :artifact_refs])),
        unresolved_findings: Enum.map(packet.unresolved_findings, &Map.take(&1, [:severity, :file, :line, :originating_sha])),
        repository_rules: Enum.map(packet.repository_rules, &Map.take(&1, [:path, :applies_to, :security_relevant, :full_rule_instruction])),
        implementation: %{
          summary: truncate(packet.implementation.summary, 300),
          known_risks: [],
          skipped_proof: packet.implementation.skipped_proof |> Enum.take(5),
          evidence_links: []
        },
        issue: %{
          packet.issue
          | requested_outcome: truncate(packet.issue.requested_outcome, 500),
            acceptance_criteria: truncate(packet.issue.acceptance_criteria, 700),
            non_goals: truncate(packet.issue.non_goals, 400)
        },
        diff: %{
          packet.diff
          | manifest: %{entries: Enum.take(packet.diff.manifest.entries, 30), total_files: packet.diff.manifest.total_files, omitted_files: max(packet.diff.manifest.total_files - 30, 0)},
            diff_stat: truncate(packet.diff.diff_stat, 600)
        }
    }
  end

  defp mark_compacted(packet, field) do
    update_in(packet, [:compaction, :compacted_fields], fn fields -> fields ++ [field] end)
  end

  defp encoded_size(packet), do: packet |> Jason.encode!(pretty: true) |> byte_size()

  defp resolve_base(workspace, pr, runner) do
    pr_base = map_string(pr, :base_oid)
    pr_ref = map_string(pr, :base_ref) || "origin/main"

    if present?(pr_base) do
      %{ref: pr_ref, sha: pr_base, source: "pull_request"}
    else
      case run_git(runner, ["rev-parse", pr_ref], workspace) do
        {:ok, sha} -> %{ref: pr_ref, sha: sha, source: "git"}
        {:error, _reason} -> %{ref: pr_ref, sha: nil, source: "unavailable"}
      end
    end
  end

  defp repository_identity(workspace, pr, runner) do
    remote = run_git_value(runner, ["remote", "get-url", "origin"], workspace)

    %{
      project: map_string(pr, :repository) || repository_from_remote(remote),
      remote: remote,
      workspace_root: run_git_value(runner, ["rev-parse", "--show-toplevel"], workspace) || workspace
    }
  end

  defp diff_evidence(workspace, base_sha, head_sha, pr, runner) do
    range = diff_range(base_sha, head_sha)

    with true <- present?(range),
         {:ok, name_status} <- run_git(runner, ["diff", "--name-status", "--find-renames", range], workspace),
         {:ok, numstat} <- run_git(runner, ["diff", "--numstat", "--find-renames", range], workspace),
         {:ok, stat} <- run_git(runner, ["diff", "--stat", "--find-renames", range], workspace),
         {:ok, raw_diff} <- run_git(runner, ["diff", "--binary", "--find-renames", range], workspace) do
      entries = merge_manifest(name_status, numstat)

      %{
        changed_files: Enum.map(entries, & &1.path),
        manifest: %{entries: entries, total_files: length(entries), omitted_files: 0},
        stat: stat,
        fingerprint: sha256(Enum.join([base_sha || "", head_sha || "", raw_diff], "\n")),
        missing_artifacts: []
      }
    else
      _failure ->
        %{
          changed_files: [],
          manifest: %{entries: [], total_files: map_integer(pr, :changed_files) || 0, omitted_files: map_integer(pr, :changed_files) || 0},
          stat: "Local diff metadata unavailable; use the authoritative full-diff instructions.",
          fingerprint: sha256(Enum.join([base_sha || "", head_sha || "", map_string(pr, :url) || ""], "\n")),
          missing_artifacts: ["local_git_diff_manifest"]
        }
    end
  end

  defp merge_manifest(name_status, numstat) do
    stats =
      numstat
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(line, "\t", parts: 3) do
          [adds, deletes, path] -> {path, %{additions: number_or_binary(adds), deletions: number_or_binary(deletes)}}
          _parts -> {line, %{additions: nil, deletions: nil}}
        end
      end)

    name_status
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      parts = String.split(line, "\t")
      status = List.first(parts) || "?"
      path = List.last(parts) || line
      Map.merge(%{status: status, path: path}, Map.get(stats, path, %{additions: nil, deletions: nil}))
    end)
  end

  defp authoritative_diff_instructions(base, head_sha, pr) do
    local =
      if present?(base.sha) and present?(head_sha) do
        "git diff --find-renames #{base.sha}...#{head_sha}"
      else
        "Resolve the pull request base and exact head, then run git diff --find-renames <base-sha>...<head-sha>."
      end

    %{
      requirement: "Inspect the complete meaningful diff. Packet compaction never authorizes reducing the candidate.",
      local_command: local,
      pull_request_command: if(map_integer(pr, :number), do: "gh pr diff #{map_integer(pr, :number)}", else: nil),
      changed_files_command: if(present?(base.sha) and present?(head_sha), do: "git diff --name-status #{base.sha}...#{head_sha}", else: nil),
      raw_artifact_request: "If these commands or an attestation are unavailable, request/read the raw artifact and record the gap; do not weaken the verdict."
    }
  end

  defp prior_review(%ReviewOutcome{} = prior, base_sha, head_sha, workspace, runner) do
    findings =
      Enum.map(prior.findings, fn finding ->
        finding
        |> Map.new()
        |> Map.put(:originating_sha, prior.reviewed_sha)
      end)

    %{
      reviewed_sha: prior.reviewed_sha,
      findings: findings,
      delta: delta_context(prior.reviewed_sha, head_sha, base_sha, workspace, runner)
    }
  end

  defp prior_review(_prior, _base_sha, head_sha, _workspace, _runner) do
    %{reviewed_sha: nil, findings: [], delta: %{kind: "first_review", prior_reviewed_sha: nil, head_sha: head_sha, command: nil, stat: nil}}
  end

  defp delta_context(prior_sha, head_sha, base_sha, workspace, runner) do
    cond do
      not present?(prior_sha) ->
        %{kind: "first_review", prior_reviewed_sha: nil, head_sha: head_sha, command: nil, stat: nil}

      prior_sha == head_sha ->
        %{kind: "same_head_recheck", prior_reviewed_sha: prior_sha, head_sha: head_sha, command: nil, stat: "No head change."}

      true ->
        command = "git diff --find-renames #{prior_sha}..#{head_sha}"

        stat =
          runner
          |> run_git_value(
            ["diff", "--stat", "--find-renames", "#{prior_sha}..#{head_sha}"],
            workspace
          )
          |> bounded_delta_stat()

        %{
          kind: "changed_head_delta",
          prior_reviewed_sha: prior_sha,
          head_sha: head_sha,
          command: command,
          stat: stat || "Delta stat unavailable; inspect the command and final full candidate diff.",
          candidate_base_sha: base_sha
        }
    end
  end

  defp review_mode(%{level: "high"}, _prior), do: "high_risk_final_full_diff"

  defp review_mode(_risk, %{reviewed_sha: nil}), do: "first_full_diff"
  defp review_mode(_risk, _prior), do: "delta_plus_full_candidate_confirmation"

  defp relevant_rules(workspace, changed_files) do
    candidates =
      (["AGENTS.md", "WORKFLOW.md"] ++ Enum.flat_map(changed_files, &rule_candidates/1))
      |> Enum.uniq()

    candidates
    |> Enum.filter(&File.regular?(Path.join(workspace, &1)))
    |> Enum.map(fn path ->
      contents = File.read!(Path.join(workspace, path))
      security_lines = security_excerpt(contents)

      %{
        path: path,
        applies_to: applicable_paths(path, changed_files),
        security_relevant: security_lines != "",
        area_excerpt: truncate(if(security_lines == "", do: contents, else: security_lines), 2_500),
        full_rule_instruction: "Read the complete file at #{path} before judging affected paths."
      }
    end)
  end

  defp rule_candidates(path) do
    path
    |> Path.dirname()
    |> ancestor_dirs()
    |> Enum.flat_map(fn dir -> [Path.join(dir, "AGENTS.md"), Path.join(dir, "WORKFLOW.md")] end)
  end

  defp ancestor_dirs("."), do: ["."]

  defp ancestor_dirs(dir) do
    Stream.unfold(dir, fn
      "." -> {".", nil}
      current -> {current, Path.dirname(current)}
    end)
    |> Enum.to_list()
  end

  defp applicable_paths("AGENTS.md", changed_files), do: changed_files
  defp applicable_paths("WORKFLOW.md", changed_files), do: changed_files

  defp applicable_paths(path, changed_files) do
    prefix = Path.dirname(path)
    Enum.filter(changed_files, &(&1 == prefix or String.starts_with?(&1, prefix <> "/")))
  end

  defp security_excerpt(contents) do
    contents
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _index} ->
      down = String.downcase(line)
      Enum.any?(@security_terms, &String.contains?(down, &1))
    end)
    |> Enum.map_join("\n", fn {line, index} -> "L#{index}: #{line}" end)
  end

  defp risk_classification(changed_files, prior, opts) do
    configured = Keyword.get(opts, :risk)

    cond do
      configured in [:high, "high"] -> %{level: "high", rationale: "Explicitly classified high risk by the handoff evidence."}
      security_paths?(changed_files) -> %{level: "high", rationale: "The candidate touches security, authentication, authorization, tenant, permission, migration, or runtime orchestration paths."}
      match?(%ReviewOutcome{review_effort: :thorough}, prior) -> %{level: "high", rationale: "The prior reviewer classified the candidate as requiring a thorough review."}
      length(changed_files) > 25 -> %{level: "medium", rationale: "The candidate spans more than 25 files and has a broad regression surface."}
      true -> %{level: "normal", rationale: "No automatic high-risk trigger matched; requested lenses still inspect the complete candidate."}
    end
  end

  defp requested_lenses(risk, changed_files, opts) do
    base = [
      %{name: "correctness", rationale: "Exercise boundary, failure, concurrency, and ordering cases in changed behavior."},
      %{name: "regression", rationale: "Trace callers and shared contracts outside the changed files."},
      %{name: "test_evidence", rationale: "Verify tests prove the changed behavior rather than merely pass."}
    ]

    security_lens =
      %{
        name: "security_tenant_auth",
        rationale: "Trust-boundary-sensitive paths require explicit authz, tenant isolation, input, and secret review."
      }

    security = if risk.level == "high" or security_paths?(changed_files), do: [security_lens], else: []

    structure =
      %{name: "structure", rationale: "Check whether the change fits repository architecture without avoidable complexity."}

    required =
      base ++ security ++ [structure]

    configured = Keyword.get(opts, :requested_lenses)

    if risk.level == "high" or security_paths?(changed_files) or not is_list(configured) do
      required
    else
      configured_names = MapSet.new(configured)

      (base ++ [security_lens, structure])
      |> Enum.filter(&MapSet.member?(configured_names, &1.name))
      |> ensure_lens(required, "correctness")
      |> ensure_lens(required, "test_evidence")
    end
  end

  defp ensure_lens(selected, required, name) do
    if Enum.any?(selected, &(&1.name == name)) do
      selected
    else
      selected ++ Enum.filter(required, &(&1.name == name))
    end
  end

  defp issue_contract(%Issue{} = issue) do
    description = issue.description || ""

    %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      requested_outcome: section_or_summary(description, ["required change", "requested outcome", "problem"]),
      acceptance_criteria: section_or_summary(description, ["acceptance criteria", "test plan", "testing"]),
      non_goals: section_or_default(description, ["non-goals", "non goals"], "No explicit non-goals were provided; do not infer scope beyond the requested outcome and acceptance criteria.")
    }
  end

  defp section_or_summary(description, headings) do
    section_or_default(description, headings, truncate(description, @text_limit))
  end

  defp section_or_default(description, headings, default) do
    Enum.find_value(headings, default, &markdown_section(description, &1)) |> truncate(@text_limit)
  end

  defp markdown_section(description, wanted) do
    lines = String.split(description, "\n")

    lines
    |> Enum.find_index(fn line -> normalize_heading(line) == wanted end)
    |> case do
      nil ->
        nil

      index ->
        lines
        |> Enum.drop(index + 1)
        |> Enum.take_while(&(normalize_heading(&1) == nil))
        |> Enum.join("\n")
        |> String.trim()
        |> case do
          "" -> nil
          value -> value
        end
    end
  end

  defp normalize_heading(line) do
    case Regex.run(~r/^\s*\#{1,6}\s+(.+?)\s*$/, line) do
      [_, heading] -> heading |> String.downcase() |> String.trim()
      _match -> nil
    end
  end

  defp implementation_context(issue, pr, diff, risk, attestations, opts) do
    defaults = %{
      summary:
        "#{diff.manifest.total_files} changed files. " <>
          truncate(diff.stat, @compact_text_limit),
      known_risks: [risk.rationale],
      skipped_proof:
        attestations.missing ++
          Enum.map(attestations.skipped, fn skipped ->
            "#{skipped.command}: #{skipped.reason} (#{skipped.originating_sha || "unknown SHA"})"
          end),
      evidence_links:
        [issue.url, map_string(pr, :url)]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    }

    %{
      summary: Keyword.get(opts, :implementation_summary, defaults.summary),
      known_risks: Keyword.get(opts, :known_risks, defaults.known_risks),
      skipped_proof: Keyword.get(opts, :skipped_proof, defaults.skipped_proof),
      evidence_links: Keyword.get(opts, :evidence_links, defaults.evidence_links)
    }
  end

  defp bounded_delta_stat(nil), do: nil
  defp bounded_delta_stat(stat), do: truncate(stat, @delta_stat_limit - byte_size("\n[compacted]"))

  defp load_attestations(workspace, head_sha, opts) do
    source = Keyword.get_lazy(opts, :attestations, fn -> read_attestations(workspace) end)

    normalize_attestations(source, head_sha)
  end

  defp read_attestations(workspace) do
    path = Path.join(workspace, ".artifacts/symphony-review/attestations.json")

    with {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw) do
      decoded
    else
      {:error, %Jason.DecodeError{}} -> :invalid
      {:error, _reason} -> :missing
    end
  end

  defp normalize_attestations(entries, head_sha) when is_list(entries) do
    normalized = Enum.map(entries, &normalize_attestation/1)
    exact = Enum.filter(normalized, &(&1.head_sha == head_sha and present?(head_sha)))
    stale = Enum.reject(normalized, &(&1.head_sha == head_sha and present?(head_sha)))

    %{
      entries: exact,
      missing: if(exact == [], do: ["exact_head_validation_attestations"], else: []),
      skipped: Enum.map(stale, &%{command: &1.command, reason: "attestation_head_mismatch", originating_sha: &1.head_sha})
    }
  end

  defp normalize_attestations(:invalid, _head_sha),
    do: %{entries: [], missing: ["malformed_attestations_artifact", "exact_head_validation_attestations"], skipped: []}

  defp normalize_attestations(_entries, _head_sha),
    do: %{entries: [], missing: ["exact_head_validation_attestations"], skipped: []}

  defp normalize_attestation(entry) when is_map(entry) do
    %{
      command: map_string(entry, :command) || "unspecified",
      head_sha: map_string(entry, :head_sha),
      status: map_string(entry, :status) || "unknown",
      duration_ms: map_integer(entry, :duration_ms),
      environment: map_string(entry, :environment) || "unspecified",
      harness_version: map_string(entry, :harness_version) || "unspecified",
      artifact_refs: map_list(entry, :artifact_refs)
    }
  end

  defp normalize_attestation(_entry), do: normalize_attestation(%{})

  defp pull_request_identity(pr) do
    %{
      number: map_integer(pr, :number),
      url: map_string(pr, :url),
      id: map_string(pr, :id)
    }
  end

  defp diff_range(base_sha, head_sha) when is_binary(base_sha) and is_binary(head_sha),
    do: "#{base_sha}...#{head_sha}"

  defp diff_range(_base_sha, _head_sha), do: nil

  defp security_paths?(paths) do
    Enum.any?(paths, fn path ->
      down = String.downcase(path)
      Enum.any?(@security_terms ++ ["migration", "orchestrator"], &String.contains?(down, &1))
    end)
  end

  defp repository_from_remote(nil), do: nil

  defp repository_from_remote(remote) do
    remote
    |> String.replace(~r/\.git$/, "")
    |> String.split(["/", ":"])
    |> Enum.take(-2)
    |> Enum.join("/")
  end

  defp run_git_value(runner, args, workspace) do
    case run_git(runner, args, workspace) do
      {:ok, value} -> value
      {:error, _reason} -> nil
    end
  end

  defp run_git(runner, args, workspace) do
    case runner.(args, workspace) do
      {:error, reason} -> {:error, reason}
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:git_exit, code, truncate(output, 400)}}
    end
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  end

  defp default_git_runner(args, workspace) do
    System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
  end

  defp map_string(nil, _key), do: nil

  defp map_string(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp map_integer(nil, _key), do: nil

  defp map_integer(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp map_list(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_list(value) -> value
      _value -> []
    end
  end

  defp number_or_binary("-"), do: "binary"

  defp number_or_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _error -> nil
    end
  end

  defp take_and_count(values, limit) when is_list(values), do: Enum.take(values, limit)
  defp take_and_count(_values, _limit), do: []

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp truncate(value, limit) when is_binary(value) and byte_size(value) > limit do
    prefix = binary_part(value, 0, limit)

    case :unicode.characters_to_binary(prefix) do
      valid when is_binary(valid) -> valid <> "\n[compacted]"
      _invalid -> String.slice(value, 0, div(limit, 2)) <> "\n[compacted]"
    end
  rescue
    _error -> String.slice(value, 0, div(limit, 2)) <> "\n[compacted]"
  end

  defp truncate(value, _limit) when is_binary(value), do: value
  defp truncate(value, _limit), do: to_string(value || "")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
