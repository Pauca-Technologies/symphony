defmodule SymphonyElixir.AgentBudget do
  @moduledoc """
  Continuation-safe, actual-thread soft-budget accounting for one agent run.

  The state carries cumulative high waters across turns. Each threshold key is
  latched after its first crossing, so duplicate/out-of-order provider usage
  snapshots and continuation turns cannot repeat a transition. Thresholds only
  change strategy; they never stop work or weaken a required quality gate.
  """

  alias SymphonyElixir.{FleetEvent, Telemetry, TokenAccounting, Utf8}

  @metric_keys [
    :total_tokens,
    :delegated_tokens,
    :per_thread_tokens,
    :per_turn_growth_tokens,
    :uncached_input_tokens,
    :cached_input_tokens,
    :tool_output_bytes,
    :elapsed_phase_ms
  ]

  @actions %{
    total_tokens: "compact_parent_resume_capsule",
    delegated_tokens: "fresh_thin_context_delegation_only",
    per_thread_tokens: "prohibit_full_history_delegation",
    per_turn_growth_tokens: "pause_and_synthesize_open_findings",
    uncached_input_tokens: "reuse_exact_head_gate_artifacts",
    cached_input_tokens: "compact_parent_resume_capsule",
    tool_output_bytes: "bound_future_tool_output",
    elapsed_phase_ms: "pause_and_synthesize_open_findings"
  }

  @type t :: %{
          decision: map(),
          issue: map(),
          high_waters: map(),
          parent_thread_id: String.t() | nil,
          crossed: term(),
          pending: [map()],
          prompt_bytes: non_neg_integer(),
          tool_output_bytes: non_neg_integer(),
          prior_turn_total: non_neg_integer(),
          turn_started_ms: integer() | nil,
          metrics: map()
        }

  @type signal :: %{
          parent_thread_id: String.t() | nil,
          thread_id: String.t(),
          usage: TokenAccounting.counters() | nil,
          tool_output_bytes: non_neg_integer()
        }

  @doc "Create accounting state that can span all continuation turns in one run."
  @spec new(map(), map()) :: t()
  def new(decision, issue) when is_map(decision) and is_map(issue) do
    %{
      decision: decision,
      issue: issue,
      high_waters: %{},
      parent_thread_id: nil,
      crossed: MapSet.new(),
      pending: [],
      prompt_bytes: 0,
      tool_output_bytes: 0,
      prior_turn_total: 0,
      turn_started_ms: nil,
      metrics: zero_metrics()
    }
  end

  @doc "Record the bounded prompt presented at the start of a turn."
  @spec start_turn(t(), String.t(), integer()) :: t()
  def start_turn(state, prompt, now_ms) when is_map(state) and is_binary(prompt) and is_integer(now_ms) do
    %{state | prompt_bytes: state.prompt_bytes + byte_size(prompt), turn_started_ms: now_ms}
  end

  @doc "Observe one backend event using actual-thread cumulative high-water semantics."
  @spec observe(t(), map()) :: t()
  def observe(state, update) when is_map(state) and is_map(update) do
    case normalize_update(update) do
      nil -> state
      signal -> apply_signal(state, signal)
    end
  end

  @doc "Reduce a full backend event to the small signal retained by the budget collector."
  @spec normalize_update(map()) :: signal() | nil
  def normalize_update(update) when is_map(update) do
    usage = TokenAccounting.extract_usage(update)
    tool_output_bytes = FleetEvent.terminal_tool_output_bytes(update)
    parent_thread_id = session_parent_thread(update)
    thread_id = TokenAccounting.actual_thread_id(update, parent_thread_id)

    if is_map(usage) or tool_output_bytes > 0 or is_binary(parent_thread_id) do
      %{
        parent_thread_id: parent_thread_id,
        thread_id: thread_id,
        usage: usage,
        tool_output_bytes: tool_output_bytes
      }
    end
  end

  @doc "Reconcile the collector's coalesced snapshot before a turn boundary."
  @spec reconcile(t(), map()) :: t()
  def reconcile(state, snapshot) when is_map(state) and is_map(snapshot) do
    state = %{
      state
      | high_waters: Map.get(snapshot, :high_waters, state.high_waters),
        parent_thread_id: Map.get(snapshot, :parent_thread_id) || state.parent_thread_id,
        tool_output_bytes: Map.get(snapshot, :tool_output_bytes, state.tool_output_bytes)
    }

    evaluate(state, metrics(state, nil))
  end

  @doc "Finish a turn, accounting elapsed time and per-turn token growth."
  @spec finish_turn(t(), integer()) :: t()
  def finish_turn(state, now_ms) when is_map(state) and is_integer(now_ms) do
    elapsed_ms =
      case state.turn_started_ms do
        started when is_integer(started) -> max(now_ms - started, 0)
        _missing -> 0
      end

    current = metrics(state, elapsed_ms)

    state
    |> evaluate(current)
    |> Map.put(:prior_turn_total, current.total_tokens)
    |> Map.put(:turn_started_ms, nil)
  end

  @doc "Take the one-shot strategy capsule for the next continuation turn."
  @spec take_strategy_prompt(t()) :: {String.t() | nil, t()}
  def take_strategy_prompt(%{pending: []} = state), do: {nil, state}

  def take_strategy_prompt(state) do
    applied = Enum.filter(state.pending, & &1.applied)
    state = %{state | pending: []}

    case applied do
      [] -> {nil, state}
      transitions -> {strategy_prompt(%{state | pending: transitions}), state}
    end
  end

  @doc "Current inspectable metrics reconstructed from actual thread high waters."
  @spec snapshot(t()) :: map()
  def snapshot(%{metrics: metrics}) when is_map(metrics), do: metrics

  defp evaluate(%{decision: %{mode: "off"}} = state, current),
    do: %{state | metrics: current}

  defp evaluate(state, current) do
    state = %{state | metrics: current}

    Enum.reduce(@metric_keys, state, fn key, acc ->
      threshold = Map.fetch!(acc.decision.budget, key)
      value = Map.fetch!(current, key)

      acc
      |> maybe_cross(key, value, threshold, "soft")
      |> maybe_cross_extreme(key, value, threshold)
    end)
  end

  defp maybe_cross(state, key, value, threshold, level) when value >= threshold do
    transition_id = "#{level}:#{key}"

    if MapSet.member?(state.crossed, transition_id) do
      state
    else
      transition = transition(state, transition_id, key, value, threshold, level)
      emit_transition(state, transition)

      %{
        state
        | crossed: MapSet.put(state.crossed, transition_id),
          pending: state.pending ++ [transition]
      }
    end
  end

  defp maybe_cross(state, _key, _value, _threshold, _level), do: state

  defp maybe_cross_extreme(state, :total_tokens = key, value, threshold) do
    extreme = trunc(threshold * state.decision.extreme_multiplier)

    if value >= extreme do
      maybe_cross(state, key, value, extreme, "extreme")
    else
      state
    end
  end

  defp maybe_cross_extreme(state, _key, _value, _threshold), do: state

  defp transition(state, transition_id, key, value, threshold, level) do
    action = if level == "extreme", do: "escalate_with_complete_resume_packet", else: Map.fetch!(@actions, key)

    %{
      transition_id: transition_id,
      dimension: Atom.to_string(key),
      level: level,
      value: value,
      threshold: threshold,
      action: action,
      proposed: true,
      applied: action_applied?(state.decision, action),
      allow_overage: state.decision.budget.allow_overage,
      quality_bar_unchanged: true
    }
  end

  defp action_applied?(%{mode: "enforce"}, _action), do: true

  defp action_applied?(%{mode: "shadow", enforced_actions: actions}, action)
       when is_list(actions),
       do: action in actions

  defp action_applied?(_decision, _action), do: false

  defp emit_transition(state, transition) do
    Telemetry.emit(:budget_transition, %{
      issue_id: state.issue.id,
      issue_identifier: state.issue.identifier,
      task_type: state.decision.task_type,
      budget_profile: state.decision.budget_profile,
      budget_mode: state.decision.mode,
      metrics: state.metrics,
      transition: transition
    })
  end

  defp metrics(state, elapsed_ms) do
    counters = Map.values(state.high_waters)
    parent = state.parent_thread_id

    total_tokens = Enum.sum(Enum.map(counters, &(&1.total_tokens || 0)))

    delegated_tokens =
      state.high_waters
      |> Enum.reject(fn {thread_id, _usage} -> thread_id == parent end)
      |> Enum.reduce(0, fn {_thread_id, usage}, sum -> sum + (usage.total_tokens || 0) end)

    input_tokens = Enum.sum(Enum.map(counters, &(&1.input_tokens || 0)))
    cached_input_tokens = Enum.sum(Enum.map(counters, &(&1.cached_input_tokens || 0)))

    %{
      total_tokens: total_tokens,
      parent_tokens: max(total_tokens - delegated_tokens, 0),
      delegated_tokens: delegated_tokens,
      per_thread_tokens: counters |> Enum.map(&(&1.total_tokens || 0)) |> Enum.max(fn -> 0 end),
      per_turn_growth_tokens: max(total_tokens - state.prior_turn_total, 0),
      uncached_input_tokens: max(input_tokens - cached_input_tokens, 0),
      cached_input_tokens: cached_input_tokens,
      prompt_bytes: state.prompt_bytes,
      tool_output_bytes: state.tool_output_bytes,
      elapsed_phase_ms: max(elapsed_ms || 0, state.metrics.elapsed_phase_ms || 0),
      thread_count: map_size(state.high_waters),
      delegated_thread_count: Enum.count(state.high_waters, fn {thread_id, _usage} -> thread_id != parent end)
    }
  end

  defp strategy_prompt(state) do
    render_capsule(
      state,
      "Apply these efficiency changes now. Continue to satisfy every acceptance criterion and required security/validation/review gate. A soft budget is never permission to approve, mark complete, skip evidence, or suppress an unresolved finding."
    )
  end

  defp render_capsule(state, policy) do
    transitions =
      Enum.map_join(state.pending, "\n", fn item ->
        "- #{item.action}: #{item.dimension}=#{item.value} crossed #{item.level} threshold #{item.threshold}."
      end)

    capsule = """
    Symphony soft-budget resume capsule

    Profile: #{state.decision.budget_profile}; task type: #{state.decision.task_type}; mode: #{state.decision.mode}.
    #{policy}

    One-shot transitions:
    #{transitions}

    Resume from the workspace/workpad and a concise inventory of remaining work. Do not delegate
    full conversation history; new reviewers or subagents must use fresh thin context. Reuse only
    exact-head validation artifacts and preserve all open findings until resolved or explicitly
    escalated.
    """

    Utf8.safe_byte_prefix(capsule, state.decision.capsule_max_bytes)
  end

  defp apply_signal(state, signal) do
    parent_thread_id = signal.parent_thread_id || state.parent_thread_id

    {high_waters, _observation} =
      case signal.usage do
        %{} = usage ->
          TokenAccounting.observe(
            state.high_waters,
            %{usage: usage, thread_id: signal.thread_id},
            parent_thread_id
          )

        nil ->
          {state.high_waters, nil}
      end

    state = %{
      state
      | high_waters: high_waters,
        parent_thread_id: parent_thread_id || reported_thread(signal.thread_id),
        tool_output_bytes: state.tool_output_bytes + signal.tool_output_bytes
    }

    evaluate(state, metrics(state, nil))
  end

  defp session_parent_thread(%{event: :session_started, thread_id: thread_id})
       when is_binary(thread_id),
       do: thread_id

  defp session_parent_thread(_update), do: nil
  defp reported_thread("thread-unreported"), do: nil
  defp reported_thread(thread_id), do: thread_id

  defp zero_metrics do
    %{
      total_tokens: 0,
      parent_tokens: 0,
      delegated_tokens: 0,
      per_thread_tokens: 0,
      per_turn_growth_tokens: 0,
      uncached_input_tokens: 0,
      cached_input_tokens: 0,
      prompt_bytes: 0,
      tool_output_bytes: 0,
      elapsed_phase_ms: 0,
      thread_count: 0,
      delegated_thread_count: 0
    }
  end
end
