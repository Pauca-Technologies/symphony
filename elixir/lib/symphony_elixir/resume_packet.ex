defmodule SymphonyElixir.ResumePacket do
  @moduledoc """
  Builds the deterministic, host-owned status packet used at resume boundaries.

  The packet is a lossy summary. It retains only bounded non-secret facts and
  stable references to raw evidence; it never persists prompt, diff, or
  workpad bodies.
  """

  alias SymphonyElixir.Linear.Comment
  alias SymphonyElixir.Utf8

  @version 1
  @max_packet_bytes 16_384
  @max_changed_paths 50
  @max_attestations 20
  @max_evidence_refs 20
  @max_warnings 10
  @max_warning_latches 32
  @max_errors 20
  @max_string_bytes 240
  @max_evidence_label_bytes 120
  @trusted_ref_suffix ".json.resume-packet.json"
  @max_count_keys 20
  @identity_reserve_bytes 192
  @experiment_assignment_reserve_bytes 1_536
  @workpad_schema_marker "codex-workpad-v1"

  @budget_metric_keys ~w(
    total_tokens parent_tokens delegated_tokens per_thread_tokens
    per_turn_growth_tokens uncached_input_tokens cached_input_tokens
    prompt_bytes tool_output_bytes elapsed_phase_ms thread_count
    delegated_thread_count
  )

  @type packet :: %{required(String.t()) => term()}
  @type packet_reference :: %{
          required(:id) => String.t(),
          required(:sha256) => String.t(),
          required(:ref) => String.t(),
          optional(:boundary) => String.t() | nil,
          optional(:evidence_refs) => [String.t()]
        }

  @doc "Current status/resume packet schema version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Hard maximum encoded size of one persisted packet."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_packet_bytes

  @doc "Build the compact trusted-sidecar reference propagated by lifecycle state."
  @spec reference(packet(), String.t()) :: packet_reference() | nil
  def reference(packet, relative_ref) when is_map(packet) and is_binary(relative_ref) do
    normalize_reference(%{
      id: packet["packet_id"],
      sha256: packet["packet_sha256"],
      ref: relative_ref,
      boundary: get_in(packet, ["boundary", "reason"]),
      evidence_refs: packet["evidence_refs"]
    })
  end

  @doc "Extract and validate a compact packet reference from AgentRunner runtime metadata."
  @spec reference_from_runtime_info(map()) :: packet_reference() | nil
  def reference_from_runtime_info(info) when is_map(info) do
    normalize_reference(%{
      id: value(info, :resume_packet_id),
      sha256: value(info, :resume_packet_sha256),
      ref: value(info, :resume_packet_ref),
      boundary: value(info, :resume_packet_boundary),
      evidence_refs: value(info, :resume_packet_evidence_refs)
    })
  end

  @doc "Normalize a persisted/runtime packet reference, returning nil for unsafe legacy data."
  @spec normalize_reference(term()) :: packet_reference() | nil
  def normalize_reference(reference) when is_map(reference) do
    id = raw_reference_string(value(reference, :id))
    sha256 = raw_reference_string(value(reference, :sha256))
    relative_ref = raw_reference_string(value(reference, :ref))

    if valid_reference_id?(id, sha256) and trusted_relative_ref?(relative_ref) do
      %{
        id: id,
        sha256: sha256,
        ref: relative_ref,
        boundary: structured_label(value(reference, :boundary)),
        evidence_refs: bounded_evidence_refs(value(reference, :evidence_refs), @max_evidence_refs)
      }
    end
  end

  def normalize_reference(_reference), do: nil

  @doc "Build one canonical packet from already-resolved host observations."
  @spec build(map(), keyword()) :: packet()
  def build(context, opts \\ []) when is_map(context) and is_list(opts) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> capture_time()
    previous = valid_previous(value(context, :previous_packet))
    repository = repository_observation(value(context, :repository), previous, now)
    workpad = workpad_observation(value(context, :issue), previous, now)
    verification = verification_observation(value(context, :verification), previous, repository, now)
    budget = budget_observation(value(context, :budget), previous, now)
    warnings = warnings_observation(value(context, :no_progress_warnings), now)

    packet =
      %{
        "protocol_version" => @version,
        "packet_id" => nil,
        "packet_sha256" => nil,
        "previous_packet_id" => previous && string(previous["packet_id"]),
        "captured_at" => now,
        "boundary" => %{
          "reason" => normalized_boundary(value(context, :boundary_reason)),
          "source" => "symphony:host",
          "captured_at" => now
        },
        "issue" => issue_identity(value(context, :issue)),
        "run" => run_identity(value(context, :identity)),
        "turns" => turns_observation(context, now),
        "repository" => repository,
        "workpad" => workpad,
        "verification" => verification,
        "budget" => budget,
        "no_progress_warnings" => warnings,
        "errors" => errors_observation(value(context, :errors), now),
        "evidence_refs" => evidence_refs(context, repository, workpad, verification),
        "unavailable_fields" => unavailable_fields(repository, workpad, verification, budget),
        "compaction" => %{"compacted_fields" => []}
      }
      |> maybe_put_experiment_assignment(value(context, :experiment_assignment))

    packet
    |> compact_to_limit()
    |> assign_identity()
  end

  @doc "Encode a validated packet with stable key ordering."
  @spec encode(packet()) :: {:ok, binary()} | {:error, :invalid_resume_packet | :packet_too_large}
  def encode(packet) when is_map(packet) do
    with :ok <- validate_packet(packet),
         encoded <- canonical_json(packet),
         true <- byte_size(encoded) <= @max_packet_bytes do
      {:ok, encoded}
    else
      false -> {:error, :packet_too_large}
      {:error, _reason} = error -> error
    end
  end

  @doc "Decode and integrity-check one persisted v1 packet."
  @spec decode(binary()) ::
          {:ok, packet()} | {:error, :invalid_resume_packet | :packet_too_large | :unsupported_version}
  def decode(payload) when is_binary(payload) do
    if byte_size(payload) > @max_packet_bytes do
      {:error, :packet_too_large}
    else
      with {:ok, packet} when is_map(packet) <- Jason.decode(payload),
           :ok <- supported_version(packet),
           :ok <- validate_packet(packet) do
        {:ok, packet}
      else
        {:error, :unsupported_version} = error -> error
        _invalid -> {:error, :invalid_resume_packet}
      end
    end
  end

  @doc "Record a lifecycle boundary without refreshing any host observation."
  @spec mark_boundary(packet(), String.t() | atom(), keyword()) ::
          {:ok, packet()} | {:error, :invalid_resume_packet}
  def mark_boundary(packet, reason, opts \\ [])
      when is_map(packet) and (is_binary(reason) or is_atom(reason)) and is_list(opts) do
    with :ok <- validate_packet(packet) do
      captured_at = opts |> Keyword.get(:now, DateTime.utc_now()) |> capture_time()

      marked =
        packet
        |> Map.put("previous_packet_id", packet["packet_id"])
        |> Map.put("packet_id", nil)
        |> Map.put("packet_sha256", nil)
        |> Map.put("boundary", %{
          "reason" => normalized_boundary(reason),
          "source" => "symphony:host",
          "captured_at" => captured_at
        })
        |> compact_to_limit()
        |> assign_identity()

      {:ok, marked}
    end
  end

  @doc "Return the bounded warning delivery/latch state from a current or legacy packet."
  @spec no_progress_state(packet() | nil) :: %{items: [term()], latched_fingerprints: [String.t()]}
  def no_progress_state(packet) when is_map(packet) do
    observation = packet_map(packet, "no_progress_warnings")
    items = bounded_warning_items(observation["items"])

    %{
      items: items,
      latched_fingerprints: bounded_warning_latches(List.wrap(observation["latched_fingerprints"]) ++ warning_item_fingerprints(items))
    }
  end

  def no_progress_state(_packet), do: %{items: [], latched_fingerprints: []}

  @doc "Compare only already-captured packet observations for post-turn progress."
  @spec progress_evidence(packet(), packet()) :: %{
          repository: :changed | :unchanged | :unavailable,
          workpad: :changed | :unchanged | :unavailable,
          exact_head: :changed | :unchanged | :unavailable
        }
  def progress_evidence(before_packet, after_packet) when is_map(before_packet) and is_map(after_packet) do
    %{
      repository:
        comparable_observation(
          packet_map(before_packet, "repository"),
          packet_map(after_packet, "repository"),
          ~w(head_sha worktree_status_fingerprint worktree_content_fingerprint)
        ),
      workpad:
        comparable_observation(
          packet_map(before_packet, "workpad"),
          packet_map(after_packet, "workpad"),
          ~w(id sha256 schema_marker updated_at)
        ),
      exact_head: exact_head_progress(before_packet, after_packet)
    }
  end

  @doc "Render the compact packet section appended to a model prompt."
  @spec render(packet(), pos_integer()) :: String.t()
  def render(packet, max_bytes) when is_map(packet) and is_integer(max_bytes) and max_bytes > 0 do
    packet = prompt_safe_packet(packet)
    repository = packet_map(packet, "repository")
    workpad = packet_map(packet, "workpad")
    verification = packet_map(packet, "verification")
    budget = packet_map(packet, "budget")
    turns = packet_map(packet, "turns")
    run = packet_map(packet, "run")

    rendered =
      """
      Symphony status/resume packet v#{packet["protocol_version"]}

      Packet: #{field(packet, "packet_id")}; previous: #{field(packet, "previous_packet_id")}; boundary: #{field(packet["boundary"], "reason")} at #{field(packet["boundary"], "captured_at")}.
      Run: run_id=#{field(run, "run_id")} parent_run_id=#{field(run, "parent_run_id")} retry_id=#{field(run, "retry_id")} retry_attempt=#{field(run, "retry_attempt")}.
      Turns [#{observation_label(turns)}]: current=#{field(turns, "current")} max=#{field(turns, "max")} remaining=#{field(turns, "remaining")}.
      Repository [#{observation_label(repository)}]: base=#{field(repository, "base_sha")} HEAD=#{field(repository, "head_sha")} dirty=#{field(repository, "dirty")} changed=#{field(repository, "changed_path_count")} paths=#{render_list(repository["changed_paths"])} omitted=#{field(repository, "changed_paths_omitted")} diff_scope=#{field(repository, "diff_scope")} diff_files=#{field(repository, "diff_files")} additions=#{field(repository, "diff_additions")} deletions=#{field(repository, "diff_deletions")} binary_files=#{field(repository, "diff_binary_files")} paths_considered=#{field(repository, "diff_paths_considered")} paths_omitted=#{field(repository, "diff_paths_omitted")}.
      Workpad [#{observation_label(workpad)}]: id=#{field(workpad, "id")} schema=#{field(workpad, "schema_marker")} updated_at=#{field(workpad, "updated_at")} sha256=#{field(workpad, "sha256")} unchecked_plan=#{field(workpad, "unchecked_plan")} unchecked_acceptance=#{field(workpad, "unchecked_acceptance")} unchecked_validation=#{field(workpad, "unchecked_validation")}.
      Verification [#{observation_label(verification)}]: current_head=#{field(verification, "current_head_status")} exact_sha=#{field(verification, "exact_sha")} gate_status=#{field(verification, "gate_status")} gate_checks=#{field(verification, "gate_check_count")} gate_source=#{field(verification, "gate_source")} gate_captured_at=#{field(verification, "gate_captured_at")} validations=#{field(verification, "validation_count")} review=#{field(verification, "review_outcome")} reviewed_sha=#{field(verification, "reviewed_sha")} review_source=#{field(verification, "review_source")} review_captured_at=#{field(verification, "review_captured_at")} open_findings=#{field(verification, "open_finding_count")} attestations_reused=#{field(verification, "attestations_reused_count")} attestations_rerun=#{field(verification, "attestations_rerun_count")}.
      Exact-head check summaries: #{render_summaries(verification["check_summaries"])}.
      Budget [#{observation_label(budget)}]: remaining=#{render_pairs(budget["remaining"])} crossed=#{render_list(budget["crossed"])}.
      No-progress warnings [#{observation_label(packet_map(packet, "no_progress_warnings"))}]: #{render_warnings(get_in(packet, ["no_progress_warnings", "items"]))}.
      Host errors [#{observation_label(packet_map(packet, "errors"))}]: #{render_list(get_in(packet, ["errors", "codes"]))}.
      Evidence refs: #{render_list(packet["evidence_refs"])}.
      Unavailable fields: #{render_list(packet["unavailable_fields"])}.
      """
      |> String.trim()

    bound_render(rendered, packet["packet_id"], max_bytes)
  end

  defp packet_map(packet, key) do
    case Map.get(packet, key) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp comparable_observation(before, %{"availability" => "current"} = current, keys) do
    comparable =
      Enum.flat_map(keys, fn key ->
        case {Map.get(before, key), Map.get(current, key)} do
          {left, right} when not is_nil(left) and not is_nil(right) -> [{left, right}]
          _unavailable -> []
        end
      end)

    cond do
      Enum.any?(comparable, fn {left, right} -> left != right end) -> :changed
      comparable != [] -> :unchanged
      true -> :unavailable
    end
  end

  defp comparable_observation(_before, _current, _keys), do: :unavailable

  defp exact_head_progress(before_packet, after_packet) do
    before = accepted_exact_head_evidence(packet_map(before_packet, "verification"))
    current = accepted_exact_head_evidence(packet_map(after_packet, "verification"))

    cond do
      current == [] -> :unavailable
      before == current -> :unchanged
      true -> :changed
    end
  end

  defp accepted_exact_head_evidence(%{"current_head_status" => "current"} = verification) do
    top_level =
      []
      |> accepted_evidence("gate", verification["gate_status"], verification["exact_sha"])
      |> accepted_evidence("review", verification["review_outcome"], verification["reviewed_sha"])

    checks =
      verification
      |> Map.get("check_summaries", [])
      |> Enum.flat_map(fn
        %{"head_status" => "current", "status" => status, "head_sha" => sha} = summary ->
          if accepted_status?(status),
            do: [Enum.join(["check", summary["kind"] || "reported", summary["name"] || "unnamed", sha], ":")],
            else: []

        _other ->
          []
      end)

    (top_level ++ checks) |> Enum.uniq() |> Enum.sort()
  end

  defp accepted_exact_head_evidence(_verification), do: []

  defp accepted_evidence(acc, kind, status, sha) do
    if accepted_status?(status) and known_git_sha?(sha), do: [Enum.join([kind, status, sha], ":") | acc], else: acc
  end

  defp accepted_status?(status),
    do: status in ~w(accepted approved complete completed pass passed success succeeded)

  defp repository_observation(repository, _previous, now) when is_map(repository) do
    paths = bounded_strings(value(repository, :actual_paths), @max_changed_paths)
    path_count = list_count(value(repository, :actual_paths))
    diff = value(repository, :diff_counts) || %{}

    %{
      "availability" => repository_availability(repository),
      "source" => "host:git",
      "captured_at" => now,
      "base_sha" => string(value(repository, :base_sha)),
      "head_sha" => string(value(repository, :head_sha)),
      "candidate_base_sha" => string(value(repository, :candidate_base_sha)),
      "dirty" => boolean(value(repository, :dirty)),
      "changed_paths" => paths,
      "changed_path_count" => path_count,
      "changed_paths_omitted" => max(path_count - length(paths), 0),
      "diff_files" => non_negative(value(diff, :files) || value(repository, :diff_files)),
      "diff_additions" => non_negative(value(diff, :additions) || value(repository, :diff_additions)),
      "diff_deletions" => non_negative(value(diff, :deletions) || value(repository, :diff_deletions)),
      "diff_binary_files" => non_negative(value(diff, :binary_files) || value(repository, :diff_binary_files)),
      "diff_paths_considered" => non_negative(value(diff, :paths_considered) || value(repository, :diff_paths_considered)),
      "diff_paths_omitted" => non_negative(value(diff, :paths_omitted) || value(repository, :diff_paths_omitted)),
      "diff_scope" => string(value(diff, :scope) || value(repository, :diff_scope)),
      "worktree_status_fingerprint" => string(value(repository, :worktree_status_fingerprint)),
      "worktree_content_fingerprint" => string(value(repository, :worktree_content_fingerprint)),
      "worktree_fingerprint_complete" => boolean(value(repository, :worktree_fingerprint_complete))
    }
  end

  defp repository_observation(_repository, %{"repository" => prior} = previous, _now) when is_map(prior) do
    prior
    |> Map.put("availability", "stale")
    |> Map.put("current_probe_error", "repository_unavailable")
    |> persisted_observation(previous)
  end

  defp repository_observation(_repository, _previous, now) do
    %{
      "availability" => "unavailable",
      "source" => "host:git",
      "captured_at" => now,
      "base_sha" => nil,
      "head_sha" => nil,
      "candidate_base_sha" => nil,
      "dirty" => nil,
      "changed_paths" => [],
      "changed_path_count" => nil,
      "changed_paths_omitted" => 0,
      "diff_files" => nil,
      "diff_additions" => nil,
      "diff_deletions" => nil,
      "diff_binary_files" => nil,
      "diff_paths_considered" => nil,
      "diff_paths_omitted" => nil,
      "diff_scope" => nil,
      "worktree_status_fingerprint" => nil,
      "worktree_content_fingerprint" => nil,
      "worktree_fingerprint_complete" => nil
    }
  end

  defp repository_availability(repository) do
    if is_binary(value(repository, :head_sha)) or is_binary(value(repository, :base_sha)) or
         is_boolean(value(repository, :dirty)),
       do: "current",
       else: "unavailable"
  end

  defp workpad_observation(issue, previous, now) do
    case current_workpad(issue) do
      %Comment{} = comment ->
        body = String.trim(comment.body)
        counts = unchecked_counts(body)
        captured_at = comment_timestamp(comment) || now
        digest = sha256(body)

        %{
          "availability" => "current",
          "source" => "linear:comment/#{string(comment.id) || "unknown"}",
          "captured_at" => captured_at,
          "id" => string(comment.id),
          "schema_marker" => @workpad_schema_marker,
          "updated_at" => comment_timestamp(comment),
          "sha256" => digest,
          "unchecked_plan" => counts.plan,
          "unchecked_acceptance" => counts.acceptance,
          "unchecked_validation" => counts.validation,
          "unchecked_total" => counts.plan + counts.acceptance + counts.validation,
          "evidence_ref" => "linear:comment/#{string(comment.id) || "unknown"}##{digest}"
        }

      nil ->
        stale_workpad(previous, now)
    end
  end

  defp stale_workpad(%{"workpad" => prior} = previous, _now) when is_map(prior) do
    prior
    |> Map.put("availability", "stale")
    |> persisted_observation(previous)
  end

  defp stale_workpad(_previous, now) do
    %{
      "availability" => "unavailable",
      "source" => "linear:workpad",
      "captured_at" => now,
      "id" => nil,
      "schema_marker" => @workpad_schema_marker,
      "updated_at" => nil,
      "sha256" => nil,
      "unchecked_plan" => nil,
      "unchecked_acceptance" => nil,
      "unchecked_validation" => nil,
      "unchecked_total" => nil,
      "evidence_ref" => nil
    }
  end

  defp current_workpad(%{comments: comments}) when is_list(comments) do
    comments
    |> Enum.filter(&workpad_comment?/1)
    |> Enum.with_index()
    |> Enum.max_by(fn {comment, index} -> {comment_timestamp_us(comment), index} end, fn -> nil end)
    |> case do
      {%Comment{} = comment, _index} -> comment
      nil -> nil
    end
  end

  defp current_workpad(_issue), do: nil

  defp workpad_comment?(%Comment{body: body}) when is_binary(body),
    do: String.starts_with?(String.trim_leading(body), "## Codex Workpad")

  defp workpad_comment?(_comment), do: false

  defp unchecked_counts(body) do
    {counts, _section} =
      body
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({%{plan: 0, acceptance: 0, validation: 0}, nil}, fn line, {counts, section} ->
        section = workpad_section(line, section)

        if section && Regex.match?(~r/^\s*[-*+]\s+\[\s\]/u, line) do
          {Map.update!(counts, section, &(&1 + 1)), section}
        else
          {counts, section}
        end
      end)

    counts
  end

  defp workpad_section(line, current) do
    case Regex.run(~r/^\s*[#]{3,6}\s+(.+?)\s*$/u, line, capture: :all_but_first) do
      [heading] -> Map.get(%{"plan" => :plan, "acceptance criteria" => :acceptance, "validation" => :validation}, String.downcase(heading))
      _not_heading -> current
    end
  end

  defp verification_observation(current, previous, repository, now) do
    previous? = not is_map(current) and is_map(previous) and is_map(previous["verification"])

    normalized =
      if previous? do
        previous["verification"]
        |> Map.put("availability", "stale")
        |> persisted_observation(previous)
      else
        normalize_verification(current, now)
      end

    head_sha = current_repository_head(repository)

    summaries =
      Enum.map(normalized["check_summaries"] || [], fn summary ->
        Map.put(summary, "head_status", evidence_head_status(summary["head_sha"], head_sha))
      end)

    candidate_shas = verification_candidate_shas(normalized, summaries)
    status = verification_head_status(head_sha, candidate_shas)

    normalized
    |> Map.put("current_head_status", status)
    |> Map.put("check_summaries", summaries)
  end

  defp current_repository_head(%{"availability" => "current", "head_sha" => head_sha}) do
    if known_git_sha?(head_sha), do: head_sha
  end

  defp current_repository_head(_repository), do: nil

  defp verification_candidate_shas(normalized, summaries) do
    [normalized["exact_sha"], normalized["reviewed_sha"]]
    |> Kernel.++(Enum.map(summaries, & &1["head_sha"]))
    |> Enum.reject(&is_nil/1)
  end

  defp verification_head_status(head_sha, _candidate_shas) when not is_binary(head_sha),
    do: "unavailable_current_head"

  defp verification_head_status(_head_sha, []), do: "unavailable"

  defp verification_head_status(head_sha, candidate_shas) do
    if Enum.all?(candidate_shas, &(&1 == head_sha)), do: "current", else: "stale"
  end

  defp normalize_verification(source, now) when is_map(source) do
    attestations = value(source, :attestation_report) || value(source, :attestations)
    findings = value(source, :severity_counts)
    evidence_refs = bounded_evidence_refs(value(source, :evidence_refs), @max_evidence_refs)
    exact_sha = git_sha(value(source, :exact_sha) || value(source, :candidate_sha))

    check_summaries =
      normalize_check_summaries(
        [
          {value(source, :checks), "gate_check"},
          {value(source, :validations), "validation"},
          {value(attestations, :reused), "attestation_reused"},
          {value(attestations, :rerun), "attestation_rerun"}
        ],
        exact_sha,
        now
      )

    %{
      "availability" => "reported",
      "source" => structured_label(value(source, :source)) || "symphony:gate_review",
      "captured_at" => structured_label(value(source, :captured_at)) || now,
      "exact_sha" => exact_sha,
      "gate_status" => structured_label(value(source, :gate_status) || value(source, :status)),
      "gate_job_id" => structured_label(value(source, :gate_job_id) || value(source, :job_id)),
      "gate_source" => structured_label(value(source, :gate_source)),
      "gate_captured_at" => structured_label(value(source, :gate_captured_at)),
      "gate_check_count" => observed_count(source, :gate_check_count, :checks),
      "validation_count" => observed_count(source, :validation_count, :validations),
      "review_outcome" => structured_label(value(source, :review_outcome) || value(source, :outcome)),
      "reviewed_sha" => git_sha(value(source, :reviewed_sha)),
      "review_packet_id" => structured_label(value(source, :review_packet_id) || value(source, :packet_id)),
      "review_source" => structured_label(value(source, :review_source)),
      "review_captured_at" => structured_label(value(source, :review_captured_at)),
      "open_finding_count" => finding_count(source, findings),
      "open_findings_by_severity" => bounded_counts(findings),
      "attestations_reused_count" => attestation_count(source, attestations, :reused),
      "attestations_rerun_count" => attestation_count(source, attestations, :rerun),
      "attestation_refs" =>
        bounded_evidence_labels(
          List.wrap(value(attestations, :reused)) ++ List.wrap(value(attestations, :rerun)),
          @max_attestations
        ),
      "check_summaries" => check_summaries,
      "evidence_refs" => evidence_refs
    }
  end

  defp normalize_verification(_source, now) do
    %{
      "availability" => "unavailable",
      "source" => "symphony:gate_review",
      "captured_at" => now,
      "exact_sha" => nil,
      "gate_status" => nil,
      "gate_job_id" => nil,
      "gate_source" => nil,
      "gate_captured_at" => nil,
      "gate_check_count" => nil,
      "validation_count" => nil,
      "review_outcome" => nil,
      "reviewed_sha" => nil,
      "review_packet_id" => nil,
      "review_source" => nil,
      "review_captured_at" => nil,
      "open_finding_count" => nil,
      "open_findings_by_severity" => %{},
      "attestations_reused_count" => nil,
      "attestations_rerun_count" => nil,
      "attestation_refs" => [],
      "check_summaries" => [],
      "evidence_refs" => [],
      "current_head_status" => "unavailable"
    }
  end

  defp budget_observation(current, _previous, now) when is_map(current) do
    metrics = bounded_numeric_map(value(current, :metrics), @budget_metric_keys)
    thresholds = bounded_numeric_map(value(current, :thresholds), @budget_metric_keys)

    remaining =
      Map.new(thresholds, fn {key, threshold} ->
        {key, max(threshold - Map.get(metrics, key, 0), 0)}
      end)

    %{
      "availability" => "current",
      "source" => "symphony:agent_budget",
      "captured_at" => now,
      "metrics" => metrics,
      "thresholds" => thresholds,
      "remaining" => remaining,
      "crossed" => bounded_strings(value(current, :transitions) || value(current, :crossed), @max_attestations)
    }
  end

  defp budget_observation(_current, %{"budget" => prior} = previous, _now) when is_map(prior) do
    prior
    |> Map.put("availability", "stale")
    |> persisted_observation(previous)
  end

  defp budget_observation(_current, _previous, now) do
    %{
      "availability" => "unavailable",
      "source" => "symphony:agent_budget",
      "captured_at" => now,
      "metrics" => %{},
      "thresholds" => %{},
      "remaining" => %{},
      "crossed" => []
    }
  end

  defp warnings_observation(warnings, now) do
    {items, latches} = warning_input(warnings)
    items = bounded_warning_items(items)

    %{
      "source" => "symphony:no_progress_detector",
      "captured_at" => now,
      "items" => items,
      "latched_fingerprints" => bounded_warning_latches(List.wrap(latches) ++ warning_item_fingerprints(items))
    }
  end

  defp warning_input(%{} = warning_state),
    do: {value(warning_state, :items) || [], value(warning_state, :latched_fingerprints) || []}

  defp warning_input(warnings), do: {warnings, []}

  defp bounded_warning_items(values) when is_list(values) do
    values
    |> Enum.flat_map(fn
      warning when is_map(warning) -> List.wrap(normalized_warning(warning))
      warning when is_binary(warning) -> List.wrap(structured_label(warning))
      _invalid -> []
    end)
    |> Enum.uniq_by(&canonical_json/1)
    |> Enum.sort_by(&canonical_json/1)
    |> Enum.take(@max_warnings)
  end

  defp bounded_warning_items(_values), do: []

  defp normalized_warning(warning) do
    normalized = %{
      version: non_negative(value(warning, :version)),
      warning_id: string(value(warning, :warning_id)),
      kind: string(value(warning, :kind)),
      fingerprint: string(value(warning, :fingerprint)),
      operation: string(value(warning, :operation)),
      result_class: string(value(warning, :result_class)),
      repeat_count: non_negative(value(warning, :repeat_count)),
      no_progress_turns: non_negative(value(warning, :no_progress_turns))
    }

    if valid_warning?(normalized) do
      %{
        "version" => 1,
        "warning_id" => normalized.warning_id,
        "kind" => normalized.kind,
        "fingerprint" => normalized.fingerprint,
        "operation" => normalized.operation,
        "result_class" => normalized.result_class,
        "repeat_count" => min(normalized.repeat_count, 1_000_000),
        "no_progress_turns" => if(is_integer(normalized.no_progress_turns), do: min(normalized.no_progress_turns, 1_000_000))
      }
    end
  end

  defp valid_warning?(warning) do
    warning.version == 1 and valid_warning_identity?(warning) and valid_warning_classification?(warning) and
      valid_warning_counts?(warning)
  end

  defp valid_warning_identity?(warning),
    do: valid_warning_id?(warning.warning_id) and valid_digest?(warning.fingerprint)

  defp valid_warning_classification?(warning) do
    warning.kind in ~w(repeated_error repeated_success_no_progress) and
      warning.operation in ~w(shell read edit web mcp dynamic other) and
      warning.result_class in ~w(success failed nonzero_exit cancelled unsupported timeout unknown_failure)
  end

  defp valid_warning_counts?(%{repeat_count: count, kind: "repeated_success_no_progress", no_progress_turns: turns}),
    do: is_integer(count) and count > 0 and is_integer(turns) and turns > 0

  defp valid_warning_counts?(%{repeat_count: count, kind: "repeated_error"}),
    do: is_integer(count) and count > 0

  defp valid_warning_id?("npw-" <> digest), do: byte_size(digest) == 24 and hex_digest?(digest)
  defp valid_warning_id?(_id), do: false

  defp valid_digest?(digest), do: is_binary(digest) and byte_size(digest) == 64 and hex_digest?(digest)
  defp hex_digest?(digest), do: Regex.match?(~r/\A[0-9a-f]+\z/, digest)

  defp bounded_warning_latches(values) do
    values
    |> List.wrap()
    |> Enum.filter(&valid_digest?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_warning_latches)
  end

  defp warning_item_fingerprints(items) do
    Enum.flat_map(items, fn
      %{"fingerprint" => fingerprint} -> [fingerprint]
      _legacy -> []
    end)
  end

  defp maybe_put_experiment_assignment(packet, assignment) when is_map(assignment) do
    if encoded_experiment_assignment_size(assignment) <= @experiment_assignment_reserve_bytes,
      do: Map.put(packet, "experiment_assignment", assignment),
      else: packet
  end

  defp maybe_put_experiment_assignment(packet, _assignment), do: packet

  defp errors_observation(errors, now) do
    %{
      "source" => "symphony:host",
      "captured_at" => now,
      "codes" => bounded_error_codes(errors)
    }
  end

  defp bounded_error_codes(errors) when is_list(errors) do
    errors
    |> Enum.flat_map(&normalized_error_code/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_errors)
  end

  defp bounded_error_codes(_errors), do: []

  defp normalized_error_code(error) do
    case string(error) do
      code when is_binary(code) -> valid_error_code(code)
      _invalid -> []
    end
  end

  defp valid_error_code(code) do
    if byte_size(code) <= 80 and Regex.match?(~r/\A[a-z][a-z0-9_.:-]*\z/, code),
      do: [code],
      else: []
  end

  defp normalize_check_summaries(groups, fallback_sha, now) do
    groups
    |> Enum.flat_map(&normalize_check_summary_group(&1, fallback_sha, now))
    |> Enum.uniq_by(&canonical_json/1)
    |> Enum.sort_by(&canonical_json/1)
    |> Enum.take(@max_attestations)
  end

  defp normalize_check_summary_group({values, kind}, fallback_sha, now) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn value ->
      case normalize_check_summary(value, kind, fallback_sha, now) do
        nil -> []
        summary -> [summary]
      end
    end)
  end

  defp normalize_check_summary(summary, kind, fallback_sha, now) when is_map(summary) do
    case summary |> first_value([:name, :check, :id, :label]) |> structured_label() do
      nil ->
        nil

      name ->
        %{
          "name" => name,
          "kind" => kind,
          "status" => summary |> first_value([:status, :outcome]) |> structured_label() |> default("reported"),
          "head_sha" => summary |> first_value([:head_sha, :sha]) |> default(fallback_sha) |> git_sha(),
          "source" => summary |> value(:source) |> structured_label() |> default("symphony:gate_review"),
          "captured_at" => summary |> value(:captured_at) |> structured_label() |> default(now),
          "evidence_ref" => summary |> first_value([:evidence_ref, :ref]) |> evidence_ref()
        }
    end
  end

  defp normalize_check_summary(summary, kind, fallback_sha, now) do
    case structured_label(summary) do
      nil ->
        nil

      name ->
        %{
          "name" => name,
          "kind" => kind,
          "status" => "reported",
          "head_sha" => fallback_sha,
          "source" => "symphony:gate_review",
          "captured_at" => now,
          "evidence_ref" => nil
        }
    end
  end

  defp first_value(map, keys) do
    Enum.reduce_while(keys, nil, fn key, _current ->
      case value(map, key) do
        nil -> {:cont, nil}
        found -> {:halt, found}
      end
    end)
  end

  defp default(nil, fallback), do: fallback
  defp default(value, _fallback), do: value

  defp evidence_head_status(evidence_sha, _head_sha) when not is_binary(evidence_sha),
    do: "unavailable_evidence_sha"

  defp evidence_head_status(_evidence_sha, head_sha) when not is_binary(head_sha),
    do: "unavailable_current_head"

  defp evidence_head_status(evidence_sha, head_sha) when is_binary(evidence_sha) do
    if evidence_sha == head_sha, do: "current", else: "stale"
  end

  defp known_git_sha?(sha) when is_binary(sha), do: Regex.match?(~r/\A[0-9a-f]{40,64}\z/i, sha)
  defp known_git_sha?(_sha), do: false

  defp valid_reference_id?("resume-packet-v1-" <> digest, digest),
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp valid_reference_id?(_id, _sha256), do: false

  defp trusted_relative_ref?(relative_ref) when is_binary(relative_ref) do
    relative_ref != "" and byte_size(relative_ref) <= @max_string_bytes and
      Path.basename(relative_ref) == relative_ref and
      not String.contains?(relative_ref, ["/", "\\"]) and
      String.ends_with?(relative_ref, @trusted_ref_suffix) and
      not String.contains?(relative_ref, "..") and
      Regex.match?(~r/\A[a-zA-Z0-9_-][a-zA-Z0-9._-]*\.json\.resume-packet\.json\z/, relative_ref)
  end

  defp trusted_relative_ref?(_relative_ref), do: false

  defp issue_identity(issue) when is_map(issue) do
    %{
      "id" => string(value(issue, :id)),
      "identifier" => string(value(issue, :identifier)),
      "updated_at" => datetime_string(value(issue, :updated_at))
    }
  end

  defp issue_identity(_issue), do: %{"id" => nil, "identifier" => nil, "updated_at" => nil}

  defp run_identity(identity) when is_map(identity) do
    %{
      "run_id" => string(value(identity, :run_id)),
      "parent_run_id" => string(value(identity, :parent_run_id)),
      "retry_id" => string(value(identity, :retry_id)),
      "retry_attempt" => non_negative(value(identity, :retry_attempt)),
      "attempt" => non_negative(value(identity, :attempt))
    }
  end

  defp run_identity(_identity),
    do: %{"run_id" => nil, "parent_run_id" => nil, "retry_id" => nil, "retry_attempt" => nil, "attempt" => nil}

  defp turns_observation(context, now) do
    current = non_negative(value(context, :turn_number))
    max_turns = non_negative(value(context, :max_turns))

    %{
      "source" => "symphony:agent_runner",
      "captured_at" => now,
      "current" => current,
      "max" => max_turns,
      "remaining" => if(is_integer(current) and is_integer(max_turns), do: max(max_turns - current, 0), else: nil)
    }
  end

  defp evidence_refs(context, repository, workpad, verification) do
    supplied = bounded_evidence_refs(value(context, :evidence_refs), @max_evidence_refs)

    check_refs =
      verification["check_summaries"]
      |> List.wrap()
      |> Enum.map(& &1["evidence_ref"])

    (supplied ++
       List.wrap(workpad["evidence_ref"]) ++
       List.wrap(if(is_binary(repository["head_sha"]), do: "git:head/#{repository["head_sha"]}")) ++
       List.wrap(
         if(is_binary(verification["review_packet_id"]),
           do: "review:packet/#{verification["review_packet_id"]}"
         )
       ) ++
       List.wrap(verification["evidence_refs"]) ++ check_refs)
    |> bounded_evidence_refs(@max_evidence_refs)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_evidence_refs)
  end

  defp unavailable_fields(repository, workpad, verification, budget) do
    []
    |> missing_if("repository.head_sha", is_nil(repository["head_sha"]))
    |> missing_if("repository.base_sha", is_nil(repository["base_sha"]))
    |> missing_if("repository.diff_counts", is_nil(repository["diff_files"]))
    |> missing_if("workpad", is_nil(workpad["id"]))
    |> missing_if("verification.current_head", verification["current_head_status"] != "current")
    |> missing_if("budget", budget["availability"] != "current")
    |> Enum.sort()
  end

  defp finding_count(source, counts) do
    case non_negative(value(source, :open_finding_count)) do
      count when is_integer(count) -> count
      nil when is_map(counts) -> counts |> bounded_counts() |> Map.values() |> Enum.sum()
      nil -> nil
    end
  end

  defp observed_count(source, count_key, values_key) do
    case non_negative(value(source, count_key)) do
      count when is_integer(count) -> count
      nil -> observed_list_count(value(source, values_key))
    end
  end

  defp attestation_count(source, attestations, kind) do
    explicit_key = if kind == :reused, do: :attestations_reused_count, else: :attestations_rerun_count

    case non_negative(value(source, explicit_key)) do
      count when is_integer(count) -> count
      nil -> observed_attestation_count(attestations, kind)
    end
  end

  defp observed_attestation_count(attestations, kind) when is_map(attestations) do
    case fetch_value(attestations, kind) do
      {:ok, values} -> observed_list_count(values)
      :error when map_size(attestations) == 0 -> 0
      :error -> nil
    end
  end

  defp observed_attestation_count(_attestations, _kind), do: nil

  defp observed_list_count(values) when is_list(values), do: length(values)
  defp observed_list_count(_values), do: nil

  defp missing_if(fields, field, true), do: [field | fields]
  defp missing_if(fields, _field, false), do: fields

  defp bounded_counts(counts) when is_map(counts) do
    counts
    |> Enum.flat_map(fn {key, count} ->
      case {structured_label(key), non_negative(count)} do
        {key, count} when is_binary(key) and is_integer(count) -> [{key, count}]
        _invalid -> []
      end
    end)
    |> Enum.sort()
    |> Enum.take(@max_count_keys)
    |> Map.new()
  end

  defp bounded_counts(_counts), do: %{}

  defp bounded_numeric_map(map, keys) when is_map(map) do
    Map.new(keys, fn key -> {key, non_negative(keyed_value(map, key))} end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp bounded_numeric_map(_map, _keys), do: %{}

  defp current_packet_body(packet), do: Map.drop(packet, ["packet_id", "packet_sha256"])

  defp prompt_safe_packet(%{"experiment_assignment" => assignment} = packet)
       when is_map(assignment) do
    prompt_packet =
      packet
      |> Map.delete("experiment_assignment")
      |> Map.put("packet_id", nil)
      |> Map.put("packet_sha256", nil)
      |> Map.update("previous_packet_id", nil, fn
        value when is_binary(value) -> "integrity-checked"
        _value -> nil
      end)
      |> scrub_persisted_sources()

    digest = prompt_packet |> current_packet_body() |> canonical_json() |> sha256()
    Map.put(prompt_packet, "packet_id", "resume-packet-v1-#{digest}")
  end

  defp prompt_safe_packet(packet), do: packet

  defp scrub_persisted_sources(packet) do
    Enum.reduce(~w(repository workpad verification budget), packet, fn field, current ->
      update_in(current, [field, "source"], fn
        "persisted:" <> _packet_id -> "persisted:trusted-resume-packet"
        source -> source
      end)
    end)
  end

  defp assign_identity(packet) do
    digest = packet |> current_packet_body() |> canonical_json() |> sha256()

    packet
    |> Map.put("packet_id", "resume-packet-v#{@version}-#{digest}")
    |> Map.put("packet_sha256", digest)
  end

  defp supported_version(%{"protocol_version" => @version}), do: :ok
  defp supported_version(%{"protocol_version" => _other}), do: {:error, :unsupported_version}
  defp supported_version(_packet), do: {:error, :invalid_resume_packet}

  defp validate_packet(
         %{
           "protocol_version" => @version,
           "packet_id" => "resume-packet-v1-" <> digest,
           "packet_sha256" => digest
         } = packet
       )
       when byte_size(digest) == 64 do
    expected = packet |> current_packet_body() |> canonical_json() |> sha256()
    if expected == digest, do: :ok, else: {:error, :invalid_resume_packet}
  end

  defp validate_packet(_packet), do: {:error, :invalid_resume_packet}

  defp valid_previous(%{"protocol_version" => @version} = packet) do
    case validate_packet(packet) do
      :ok -> packet
      {:error, _reason} -> nil
    end
  end

  defp valid_previous(_packet), do: nil

  defp compact_to_limit(packet) do
    {assignment, visible_packet} = Map.pop(packet, "experiment_assignment")

    body_limit =
      @max_packet_bytes - @identity_reserve_bytes -
        if(is_map(assignment), do: @experiment_assignment_reserve_bytes, else: 0)

    compacted = compact_visible_to_limit(visible_packet, body_limit)
    maybe_put_experiment_assignment(compacted, assignment)
  end

  defp compact_visible_to_limit(packet, body_limit) do
    steps = [
      &compact_paths(&1, 20),
      &compact_verification(&1, 8),
      &compact_refs(&1, 10),
      &compact_warnings(&1, 5),
      &compact_errors(&1, 10),
      &compact_paths(&1, 0),
      &compact_verification(&1, 0)
    ]

    Enum.reduce_while(steps, packet, fn step, current ->
      if encoded_body_size(current) <= body_limit do
        {:halt, current}
      else
        {:cont, step.(current)}
      end
    end)
  end

  defp compact_paths(packet, limit) do
    paths = get_in(packet, ["repository", "changed_paths"]) || []
    kept = Enum.take(paths, limit)
    removed = length(paths) - length(kept)

    if removed > 0 do
      packet
      |> put_in(["repository", "changed_paths"], kept)
      |> update_in(["repository", "changed_paths_omitted"], &((&1 || 0) + removed))
      |> mark_compacted("repository.changed_paths")
    else
      packet
    end
  end

  defp compact_verification(packet, limit) do
    fields = ["attestation_refs", "evidence_refs", "check_summaries"]

    {packet, omitted?} =
      Enum.reduce(fields, {packet, false}, fn field, {current, omitted?} ->
        values = get_in(current, ["verification", field]) || []
        kept = Enum.take(values, limit)
        {put_in(current, ["verification", field], kept), omitted? or length(kept) < length(values)}
      end)

    if omitted?, do: mark_compacted(packet, "verification.details"), else: packet
  end

  defp compact_refs(packet, limit) do
    compact_top_level_list(packet, "evidence_refs", limit)
  end

  defp compact_warnings(packet, limit) do
    compact_nested_list(packet, "no_progress_warnings", "items", limit)
  end

  defp compact_errors(packet, limit), do: compact_nested_list(packet, "errors", "codes", limit)

  defp compact_top_level_list(packet, field, limit) do
    values = packet[field] || []
    kept = Enum.take(values, limit)

    if length(kept) < length(values) do
      packet |> Map.put(field, kept) |> mark_compacted(field)
    else
      packet
    end
  end

  defp compact_nested_list(packet, group, field, limit) do
    values = get_in(packet, [group, field]) || []
    kept = Enum.take(values, limit)

    if length(kept) < length(values) do
      packet |> put_in([group, field], kept) |> mark_compacted(group <> "." <> field)
    else
      packet
    end
  end

  defp mark_compacted(packet, field) do
    update_in(packet, ["compaction", "compacted_fields"], fn fields ->
      (fields ++ [field]) |> Enum.uniq()
    end)
  end

  defp encoded_body_size(packet), do: packet |> current_packet_body() |> canonical_json() |> byte_size()

  defp encoded_experiment_assignment_size(assignment),
    do: %{"experiment_assignment" => assignment} |> canonical_json() |> byte_size()

  defp bound_render(rendered, packet_id, max_bytes) do
    if byte_size(rendered) <= max_bytes do
      rendered
    else
      suffix = "\n…[status packet truncated; full evidence packet #{packet_id}]"
      prefix_bytes = max(max_bytes - byte_size(suffix), 0)
      Utf8.safe_byte_prefix(rendered, prefix_bytes) <> Utf8.safe_byte_prefix(suffix, max_bytes - prefix_bytes)
    end
  end

  defp persisted_observation(observation, previous) do
    observation
    |> Map.put("source", "persisted:#{previous["packet_id"]}")
    |> Map.put_new("captured_at", nil)
  end

  defp capture_time(%DateTime{} = time), do: time |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp capture_time(time) when is_binary(time), do: truncate(time, @max_string_bytes)
  defp capture_time(_time), do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp comment_timestamp(%Comment{} = comment),
    do: datetime_string(comment.updated_at || comment.created_at)

  defp comment_timestamp_us(%Comment{} = comment) do
    case comment.updated_at || comment.created_at do
      %DateTime{} = timestamp -> DateTime.to_unix(timestamp, :microsecond)
      _unknown -> 0
    end
  end

  defp datetime_string(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_string(value), do: string(value)

  defp normalized_boundary(value), do: string(value) || "unspecified"

  defp render_pairs(map) when is_map(map) and map_size(map) > 0 do
    map |> Enum.sort() |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp render_pairs(_map), do: "unavailable"
  defp render_list(values) when is_list(values) and values != [], do: Enum.join(values, ", ")
  defp render_list(_values), do: "none"

  defp render_warnings(values) when is_list(values) do
    values
    |> Enum.flat_map(&render_warning/1)
    |> Enum.uniq()
    |> case do
      [] -> "none"
      warnings -> Enum.join(warnings, " ")
    end
  end

  defp render_warnings(_values), do: "none"

  defp render_warning(%{"kind" => "repeated_error"} = warning) do
    [
      "Repeated ",
      warning["operation"],
      " attempts ended as ",
      warning["result_class"],
      " ",
      Integer.to_string(warning["repeat_count"]),
      " times without observable progress; reassess evidence and approach before repeating the same operation."
    ]
    |> IO.iodata_to_binary()
    |> List.wrap()
  end

  defp render_warning(%{"kind" => "repeated_success_no_progress"} = warning) do
    [
      "Repeated successful ",
      warning["operation"],
      " attempts produced no observable progress across ",
      Integer.to_string(warning["no_progress_turns"] || 0),
      " boundaries; reassess evidence and approach before repeating the same operation."
    ]
    |> IO.iodata_to_binary()
    |> List.wrap()
  end

  defp render_warning(warning) when is_binary(warning),
    do: ["A legacy no-progress warning is pending; reassess evidence and approach before repeating work."]

  defp render_warning(_invalid), do: []

  defp render_summaries(summaries) when is_list(summaries) and summaries != [] do
    Enum.map_join(summaries, "; ", fn summary ->
      "#{field(summary, "kind")}:#{field(summary, "name")}=#{field(summary, "status")}" <>
        "@#{field(summary, "head_sha")}[#{field(summary, "head_status")}]" <>
        " ref=#{field(summary, "evidence_ref")}"
    end)
  end

  defp render_summaries(_summaries), do: "none"

  defp observation_label(observation) do
    "#{field(observation, "source")} at #{field(observation, "captured_at")}"
  end

  defp field(map, key) when is_map(map) do
    case map[key] do
      nil -> "unavailable"
      value -> to_string(value)
    end
  end

  defp field(_map, _key), do: "unavailable"

  defp bounded_strings(values, limit) when is_list(values) do
    values
    |> Enum.flat_map(fn value -> if is_binary(string(value)), do: [string(value)], else: [] end)
    |> Enum.map(&truncate(&1, @max_string_bytes))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(limit)
  end

  defp bounded_strings(_values, _limit), do: []

  defp bounded_evidence_labels(values, limit) when is_list(values) do
    values
    |> Enum.flat_map(fn value ->
      case structured_label(value) do
        nil -> []
        label -> [label]
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(limit)
  end

  defp bounded_evidence_refs(values, limit) when is_list(values) do
    values
    |> Enum.flat_map(fn value ->
      case evidence_ref(value) do
        nil -> []
        reference -> [reference]
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(limit)
  end

  defp bounded_evidence_refs(_values, _limit), do: []

  defp evidence_ref(value) when is_binary(value) do
    if safe_evidence_ref?(value), do: value
  end

  defp evidence_ref(_value), do: nil

  defp safe_evidence_ref?(value) do
    String.valid?(value) and value != "" and byte_size(value) <= @max_string_bytes and
      value == String.trim(value) and not Regex.match?(~r/[[:space:][:cntrl:]]/u, value) and
      not String.contains?(value, "\\") and
      (known_evidence_ref?(value) or safe_artifact_ref?(value))
  end

  defp known_evidence_ref?(value) do
    case String.split(value, ":", parts: 2) do
      [namespace, payload] when namespace in ~w(gate review linear git) ->
        Regex.match?(~r/\A[A-Za-z0-9._\/:#@+=-]+\z/u, payload) and
          payload
          |> String.split("/")
          |> Enum.all?(&(&1 not in ["", ".", ".."]))

      _invalid ->
        false
    end
  end

  defp safe_artifact_ref?(value) do
    String.starts_with?(value, [".artifacts/", "artifacts/"]) and
      Path.type(value) == :relative and
      value
      |> Path.split()
      |> Enum.all?(&safe_artifact_segment?/1)
  end

  defp safe_artifact_segment?(segment) do
    segment not in ["", ".", ".."] and Regex.match?(~r/\A[.A-Za-z0-9_-]+\z/u, segment)
  end

  defp list_count(values) when is_list(values), do: length(values)
  defp list_count(_values), do: 0

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(value) when is_float(value) and value >= 0, do: value
  defp non_negative(_value), do: nil

  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_value), do: nil

  defp string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> truncate(trimmed, @max_string_bytes)
    end
  end

  defp string(value) when is_atom(value) and not is_nil(value), do: value |> Atom.to_string() |> string()
  defp string(_value), do: nil

  defp structured_label(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> structured_label()

  defp structured_label(value) when is_binary(value) do
    if String.valid?(value) and not Regex.match?(~r/[[:cntrl:]]/u, value) do
      value
      |> String.trim()
      |> String.replace(~r/ +/u, " ")
      |> case do
        "" -> nil
        label -> truncate(label, @max_evidence_label_bytes)
      end
    end
  end

  defp structured_label(_value), do: nil

  defp git_sha(value) do
    case string(value) do
      sha when is_binary(sha) -> if known_git_sha?(sha), do: sha
      _invalid -> nil
    end
  end

  defp raw_reference_string(value) when is_binary(value) do
    if String.valid?(value), do: value
  end

  defp raw_reference_string(_value), do: nil

  defp truncate(value, max_bytes), do: Utf8.safe_byte_prefix(value, max_bytes)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(_map, _key), do: nil

  defp fetch_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp keyed_value(map, key) do
    Enum.find_value(map, fn
      {candidate, value} when is_binary(candidate) and candidate == key ->
        {:found, value}

      {candidate, value} when is_atom(candidate) ->
        if Atom.to_string(candidate) == key, do: {:found, value}

      _entry ->
        nil
    end)
    |> case do
      {:found, value} -> value
      nil -> nil
    end
  end

  defp canonical_json(%_{} = struct), do: struct |> Map.from_struct() |> canonical_json()

  defp canonical_json(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, value} -> Jason.encode!(key) <> ":" <> canonical_json(value) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(list) when is_list(list),
    do: list |> Enum.map_join(",", &canonical_json/1) |> then(&("[" <> &1 <> "]"))

  defp canonical_json(value) when is_boolean(value) or is_nil(value), do: Jason.encode!(value)

  defp canonical_json(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> Jason.encode!()

  defp canonical_json(value), do: Jason.encode!(value)

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
