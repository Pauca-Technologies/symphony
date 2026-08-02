defmodule SymphonyElixir.Telemetry.Report do
  @moduledoc """
  Builds bounded fleet efficiency and quality reports from versioned events.

  Token totals are reconstructed exclusively from the greatest cumulative
  snapshot observed for each actual thread. Accepted deltas are included for
  auditability but never summed by the report, preventing duplicate absolute
  snapshots from inflating fleet, issue, or delegation totals.
  """

  @token_keys ~w(input_tokens cached_input_tokens output_tokens reasoning_tokens total_tokens)a
  @zero_tokens Map.new(@token_keys, &{&1, 0})

  @doc "Build all fleet/repository/issue/thread/phase/failure report views."
  @spec build([map()], Date.t() | nil, Date.t() | nil) :: map()
  def build(events, from \\ nil, to \\ nil) when is_list(events) do
    grouped = Enum.group_by(events, & &1["event"])
    starts = Map.get(grouped, "run_start", [])
    ends = Map.get(grouped, "run_end", [])
    review_events = Map.get(grouped, "review", [])

    token_threads =
      token_thread_high_waters(Map.get(grouped, "token_high_water", []) ++ review_token_events(review_events))

    phases = phase_view(Map.get(grouped, "phase", []), ends)
    tools = Map.get(grouped, "tool", [])
    gates = Map.get(grouped, "gate", []) ++ Map.get(grouped, "review", [])
    retries = Map.get(grouped, "retry_policy", [])

    durations = values(ends, "duration_ms")
    thread_tokens = token_threads |> Map.values() |> Enum.map(& &1.tokens.total_tokens)
    issue_views = grouped_token_view(token_threads, & &1.issue_identifier)
    repository_views = grouped_token_view(token_threads, & &1.repository)
    parent_views = parent_subagent_view(token_threads)
    totals = sum_token_threads(token_threads)
    delegated_tokens = delegated_total(token_threads)

    summary = %{
      schema_version: 1,
      window: %{from: format_date(from), to: format_date(to)},
      fleet: %{
        run_starts: length(starts),
        run_ends: length(ends),
        completion_rate: rate(length(ends), length(starts)),
        tokens: totals,
        tokens_p50: percentile(thread_tokens, 0.5),
        tokens_p90: percentile(thread_tokens, 0.9),
        duration_ms_p50: percentile(durations, 0.5),
        duration_ms_p90: percentile(durations, 0.9),
        delegation_share: ratio(delegated_tokens, totals.total_tokens),
        output_bytes: output_bytes(tools),
        gate_reuse: gate_reuse(gates),
        retries_by_class: tally(retries, "failure_class"),
        outcomes: tally(ends, "outcome"),
        quality_guardrails: quality_guardrails(grouped, gates)
      },
      repositories: repository_views,
      issues: issue_views,
      parent_subagents: parent_views,
      phases: phases,
      failures: failure_view(grouped, retries),
      tools: tool_view(tools),
      reviews: review_view(review_events),
      routing: %{
        routing_skips: length(Map.get(grouped, "routing_skip", [])),
        cardinality_skips: length(Map.get(grouped, "cardinality_skip", []))
      },
      gc: %{
        passes: length(Map.get(grouped, "gc_pass_summary", [])),
        removed: length(Map.get(grouped, "gc_removed", [])),
        skipped: length(Map.get(grouped, "gc_skipped", []))
      }
    }

    Map.merge(summary, legacy_aliases(summary))
  end

  @doc "Greatest cumulative counters observed for every actual thread."
  @spec token_thread_high_waters([map()]) :: map()
  def token_thread_high_waters(events) when is_list(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      thread_id = thread_identity(event)
      cumulative = normalize_tokens(event["cumulative"] || %{})
      existing = Map.get(acc, thread_id, thread_record(event, thread_id))

      updated = %{
        existing
        | tokens: max_tokens(existing.tokens, cumulative),
          issue_identifier: present(event["issue_identifier"]) || existing.issue_identifier,
          parent_issue_id: present(event["parent_issue_id"]) || existing.parent_issue_id,
          repository: present(event["repository"]) || existing.repository,
          parent_thread_id: present(event["parent_thread_id"]) || existing.parent_thread_id,
          role: present(event["thread_role"]) || existing.role
      }

      Map.put(acc, thread_id, updated)
    end)
  end

  @doc "Conventional nearest-rank percentile used consistently in JSON and text reports."
  @spec percentile([number()], number()) :: number() | nil
  def percentile(values, q) when is_list(values) and q >= 0 and q <= 1 do
    case Enum.sort(values) do
      [] -> nil
      sorted -> Enum.at(sorted, max(ceil(q * length(sorted)), 1) - 1)
    end
  end

  defp legacy_aliases(summary) do
    %{
      from: summary.window.from,
      to: summary.window.to,
      run_starts: summary.fleet.run_starts,
      run_ends: summary.fleet.run_ends,
      completion_rate: summary.fleet.completion_rate,
      duration_ms_median: summary.fleet.duration_ms_p50,
      duration_ms_p90: summary.fleet.duration_ms_p90,
      routing_skips: summary.routing.routing_skips,
      cardinality_skips: summary.routing.cardinality_skips,
      outcomes: summary.fleet.outcomes,
      gc: summary.gc
    }
  end

  defp thread_record(event, thread_id) do
    %{
      thread_id: thread_id,
      parent_thread_id: present(event["parent_thread_id"]),
      role: present(event["thread_role"]) || "parent",
      issue_identifier: present(event["issue_identifier"]) || "unknown",
      parent_issue_id: present(event["parent_issue_id"]),
      repository: present(event["repository"]) || "default",
      tokens: @zero_tokens
    }
  end

  defp thread_identity(event) do
    case present(event["thread_id"]) do
      reported when reported not in [nil, "thread-unreported", "review-thread-unreported"] ->
        reported

      _missing ->
        context =
          [
            {"packet", event["packet_id"]},
            {"session", event["session_id"]},
            {"issue", event["issue_identifier"] || event["issue_id"]},
            {"parent", event["parent_issue_id"]},
            {"repository", event["repository"]},
            {"role", event["thread_role"] || event["role"]}
          ]
          |> Enum.flat_map(&thread_context_part/1)
          |> Enum.join(":")

        if context == "", do: "thread-unreported", else: "thread-unreported:#{context}"
    end
  end

  defp thread_context_part({name, value}) do
    case present(value) do
      nil -> []
      present_value -> ["#{name}=#{present_value}"]
    end
  end

  defp normalize_tokens(tokens) when is_map(tokens) do
    Map.new(@token_keys, fn key -> {key, non_negative(tokens[Atom.to_string(key)] || tokens[key])} end)
  end

  defp normalize_tokens(_tokens), do: @zero_tokens

  defp max_tokens(left, right), do: Map.new(@token_keys, &{&1, max(left[&1] || 0, right[&1] || 0)})

  defp sum_token_threads(threads),
    do: Enum.reduce(threads, @zero_tokens, fn {_id, thread}, acc -> add_tokens(acc, thread.tokens) end)

  defp add_tokens(left, right), do: Map.new(@token_keys, &{&1, (left[&1] || 0) + (right[&1] || 0)})

  defp grouped_token_view(threads, key_fun) do
    threads
    |> Enum.group_by(fn {_id, thread} -> key_fun.(thread) || "unknown" end)
    |> Map.new(fn {key, rows} ->
      tokens = Enum.reduce(rows, @zero_tokens, fn {_id, thread}, acc -> add_tokens(acc, thread.tokens) end)
      totals = Enum.map(rows, fn {_id, thread} -> thread.tokens.total_tokens end)

      {key,
       %{
         thread_count: length(rows),
         tokens: tokens,
         tokens_p50: percentile(totals, 0.5),
         tokens_p90: percentile(totals, 0.9),
         delegated_threads: Enum.count(rows, fn {_id, thread} -> thread.role == "delegated" end)
       }}
    end)
  end

  defp parent_subagent_view(threads) do
    threads
    |> Enum.group_by(fn {thread_id, thread} -> thread.parent_thread_id || thread_id end)
    |> Map.new(fn {parent_id, rows} ->
      parent = Enum.filter(rows, fn {thread_id, thread} -> thread.role != "delegated" or thread_id == parent_id end)
      delegated = Enum.filter(rows, fn {_thread_id, thread} -> thread.role == "delegated" end)
      parent_tokens = rows_tokens(parent)
      delegated_tokens = rows_tokens(delegated)

      {parent_id,
       %{
         parent_threads: length(parent),
         delegated_threads: length(delegated),
         parent_tokens: parent_tokens,
         delegated_tokens: delegated_tokens,
         total_tokens: add_tokens(parent_tokens, delegated_tokens)
       }}
    end)
  end

  defp rows_tokens(rows), do: Enum.reduce(rows, @zero_tokens, fn {_id, thread}, acc -> add_tokens(acc, thread.tokens) end)

  defp delegated_total(threads) do
    threads
    |> Enum.filter(fn {_id, thread} -> thread.role == "delegated" end)
    |> Enum.reduce(0, fn {_id, thread}, acc -> acc + thread.tokens.total_tokens end)
  end

  defp review_token_events(events) do
    Enum.flat_map(events, fn event ->
      if is_number(event["tokens"]) do
        [
          %{
            "thread_id" => event["thread_id"],
            "parent_thread_id" => event["parent_thread_id"],
            "thread_role" => if(event["role"] == "lens", do: "delegated", else: "parent"),
            "packet_id" => event["packet_id"],
            "session_id" => event["session_id"],
            "issue_identifier" => event["issue_identifier"],
            "parent_issue_id" => event["parent_issue_id"],
            "repository" => event["repository"] || "default",
            "cumulative" => %{"total_tokens" => event["tokens"]}
          }
        ]
      else
        []
      end
    end)
  end

  defp review_view(events) do
    thread_events = Enum.filter(events, &is_number(&1["tokens"]))
    verdict_events = authoritative_review_verdicts(events)

    packets =
      thread_events
      |> Enum.group_by(&(&1["packet_id"] || "packet-unreported"))
      |> Map.new(fn {packet_id, rows} ->
        {packet_id,
         %{
           bytes: rows |> values("packet_bytes") |> Enum.max(fn -> nil end),
           threads: length(rows),
           lenses: requested_lens_names(rows),
           tokens: rows |> values("tokens") |> Enum.sum(),
           duration_ms: rows |> values("duration_ms") |> Enum.sum(),
           verdicts: verdicts_for_packet(verdict_events, packet_id),
           findings_by_severity: findings_for_packet(verdict_events, packet_id)
         }}
      end)

    %{
      packets: packets,
      tokens: thread_events |> values("tokens") |> Enum.sum(),
      duration_ms_p50: percentile(values(thread_events, "duration_ms"), 0.5),
      duration_ms_p90: percentile(values(thread_events, "duration_ms"), 0.9),
      verdicts: tally(verdict_events, "outcome"),
      findings_by_severity: severity_tally(verdict_events)
    }
  end

  defp phase_view(events, run_ends) do
    terminals_by_issue =
      run_ends
      |> Enum.group_by(& &1["issue_identifier"], &timestamp_ms(&1["ts"]))
      |> Map.new(fn {issue, timestamps} -> {issue, timestamps |> Enum.filter(&is_integer/1) |> Enum.sort()} end)

    events
    |> Enum.group_by(&{&1["issue_identifier"], &1["session_id"], &1["thread_id"]})
    |> Enum.flat_map(fn {{issue, _session, _thread}, rows} ->
      phase_durations(rows, terminal_for_phase_group(rows, terminals_by_issue[issue] || []))
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {phase, durations} ->
      valid = Enum.filter(durations, &is_integer/1)
      {phase, %{transitions: length(durations), duration_ms: Enum.sum(valid), duration_ms_p50: percentile(valid, 0.5), duration_ms_p90: percentile(valid, 0.9)}}
    end)
  end

  defp terminal_for_phase_group(rows, terminals) do
    final_transition = rows |> Enum.map(&timestamp_ms(&1["ts"])) |> Enum.filter(&is_integer/1) |> Enum.max(fn -> nil end)
    Enum.find(terminals, &(is_integer(final_transition) and &1 >= final_transition))
  end

  defp phase_durations(rows, terminal_at) do
    sorted = Enum.sort_by(rows, &timestamp_ms(&1["ts"]))

    sorted
    |> Enum.with_index()
    |> Enum.map(&phase_duration(&1, sorted, terminal_at))
  end

  defp phase_duration({event, index}, sorted, terminal_at) do
    started = timestamp_ms(event["ts"])
    finished = Enum.at(sorted, index + 1) |> next_phase_timestamp(terminal_at)
    {event["phase"] || "unknown", duration_between(started, finished)}
  end

  defp next_phase_timestamp(nil, terminal_at), do: terminal_at
  defp next_phase_timestamp(event, _terminal_at), do: timestamp_ms(event["ts"])

  defp failure_view(grouped, retries) do
    explicit = Map.get(grouped, "failure", [])
    legacy_fallback = unmatched_error_run_ends(explicit, Map.get(grouped, "run_end", []))

    %{
      by_class: tally(explicit ++ legacy_fallback, "failure_class"),
      retry_actions: tally(retries, "action"),
      circuits: tally(Map.get(grouped, "quota_circuit", []), "action")
    }
  end

  defp unmatched_error_run_ends(explicit, run_ends) do
    counts = Enum.frequencies_by(explicit, &failure_identity/1)

    run_ends
    |> Enum.filter(&(&1["outcome"] == "error"))
    |> Enum.reduce({counts, []}, fn event, {remaining, fallback} ->
      identity = failure_identity(event)

      case Map.get(remaining, identity, 0) do
        count when count > 0 -> {Map.put(remaining, identity, count - 1), fallback}
        _missing -> {remaining, [event | fallback]}
      end
    end)
    |> elem(1)
  end

  defp failure_identity(event) do
    {
      event["issue_id"] || event["issue_identifier"],
      event["repository"],
      event["worker_host"],
      event["failure_class"] || "unknown"
    }
  end

  defp tool_view(tools) do
    completed = Enum.filter(tools, &(&1["action"] == "end"))

    %{
      completed: length(completed),
      by_category: tally(completed, "category"),
      by_outcome: tally(completed, "outcome"),
      duration_ms_p50: percentile(values(completed, "duration_ms"), 0.5),
      duration_ms_p90: percentile(values(completed, "duration_ms"), 0.9),
      output_bytes: output_bytes(completed)
    }
  end

  defp gate_reuse(gates) do
    Enum.reduce(gates, %{reused: 0, rerun: 0, reuse_rate: nil}, fn event, acc ->
      attestation = event["attestation_report"] || event["attestations"] || %{}
      reused = list_length(attestation["reused"] || event["attestations_reused"])
      rerun = list_length(attestation["rerun"] || event["attestations_rerun"])
      %{acc | reused: acc.reused + reused, rerun: acc.rerun + rerun}
    end)
    |> then(fn counts -> Map.put(counts, :reuse_rate, ratio(counts.reused, counts.reused + counts.rerun)) end)
  end

  defp quality_guardrails(grouped, gates) do
    quality = Map.get(grouped, "quality_outcome", [])
    gate_outcomes = Enum.reject(gates, &(&1["subtype"] == "review_thread"))
    verdicts = authoritative_review_verdicts(gates)

    %{
      outcomes: tally(quality, "outcome"),
      gate_outcomes: tally(gate_outcomes, "outcome"),
      review_findings_by_severity: severity_tally(verdicts),
      reopens: Enum.count(quality, &(&1["outcome"] == "reopen")),
      merges: Enum.count(quality, &(&1["outcome"] == "merge")),
      reverts: Enum.count(quality, &(&1["outcome"] == "revert")),
      ci_regressions: Enum.count(quality, &(&1["outcome"] == "ci_regression"))
    }
  end

  defp authoritative_review_verdicts(events) do
    events
    |> Enum.filter(fn event ->
      event["subtype"] == "review" or
        (event["event"] == "review" and is_nil(event["subtype"]) and is_map(event["severity_counts"]))
    end)
    |> Enum.uniq_by(fn event ->
      {event["packet_id"] || event["reviewed_sha"] || event["issue_identifier"], event["outcome"], event["iteration"]}
    end)
  end

  defp verdicts_for_packet(events, packet_id), do: events |> packet_events(packet_id) |> tally("outcome")
  defp findings_for_packet(events, packet_id), do: events |> packet_events(packet_id) |> severity_tally()

  defp packet_events(events, packet_id),
    do: Enum.filter(events, &((&1["packet_id"] || "packet-unreported") == packet_id))

  defp requested_lens_names(rows) do
    rows
    |> Enum.flat_map(&List.wrap(&1["requested_lenses"]))
    |> Enum.map(fn
      %{"name" => name} -> name
      %{name: name} -> name
      name when is_binary(name) -> name
      _unknown -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp severity_tally(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      Enum.reduce(event["severity_counts"] || %{}, acc, fn {severity, count}, nested ->
        Map.update(nested, severity, non_negative(count), &(&1 + non_negative(count)))
      end)
    end)
  end

  defp output_bytes(tools), do: tools |> values("output_bytes") |> Enum.sum()

  defp values(events, key),
    do: Enum.flat_map(events, fn event -> if is_number(event[key]) and event[key] >= 0, do: [event[key]], else: [] end)

  defp tally(events, key) do
    Enum.reduce(events, %{}, fn event, acc -> Map.update(acc, present(event[key]) || "unknown", 1, &(&1 + 1)) end)
  end

  defp rate(_part, 0), do: nil
  defp rate(part, total), do: Float.round(part / total, 4)
  defp ratio(_part, 0), do: nil
  defp ratio(part, total), do: Float.round(part / total, 4)

  defp list_length(value) when is_list(value), do: length(value)
  defp list_length(value) when is_integer(value) and value >= 0, do: value
  defp list_length(_value), do: 0

  defp timestamp_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> DateTime.to_unix(timestamp, :millisecond)
      _invalid -> nil
    end
  end

  defp timestamp_ms(_value), do: nil
  defp duration_between(started, finished) when is_integer(started) and is_integer(finished), do: max(finished - started, 0)
  defp duration_between(_started, _finished), do: nil

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(value) when is_float(value) and value >= 0, do: trunc(value)
  defp non_negative(_value), do: 0

  defp present(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp present(_value), do: nil
  defp format_date(nil), do: nil
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
end
