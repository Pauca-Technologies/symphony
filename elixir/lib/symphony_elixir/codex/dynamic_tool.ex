defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{BaseDrift, HandoffGate, Linear.Client, ReviewGate, ReviewOutcome}

  @linear_graphql_tool "linear_graphql"
  @issue_transition_query """
  query SymphonyResolveIssueTransition($issueId: String!) {
    issue(id: $issueId) {
      state {
        name
      }
      team {
        states(first: 250) {
          nodes {
            id
            name
          }
        }
      }
    }
  }
  """
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear. In Progress to review-state issueUpdate mutations invoke Symphony's before_handoff and automated review gates.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         :ok <- maybe_run_before_handoff_gate(query, variables, opts, linear_client),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:handoff_blocked, prompt, gates} ->
        failure_response(%{
          "error" => %{
            "message" => "before_handoff hook blocked the Linear status transition.",
            "remediation" => prompt,
            "gates" => gates
          }
        })

      {:handoff_infrastructure_error, prompt, gate} ->
        notify_handoff_infrastructure_failure(opts, prompt, gate)

        failure_response(%{
          "error" => %{
            "message" => "The asynchronous before_handoff gate could not be verified.",
            "remediation" => prompt,
            "gate" => protocol_gate_payload(gate)
          }
        })

      {:base_drift_blocked, prompt, decision} ->
        failure_response(%{
          "error" => %{
            "message" => "Base drift blocked stale-head final validation and review.",
            "remediation" => prompt,
            "baseDrift" => decision
          }
        })

      {:review_blocked, prompt, findings, review_outcome} ->
        failure_response(%{
          "error" => %{
            "message" => "Automated review did not approve the In Review handoff.",
            "remediation" => prompt,
            "findings" => findings,
            "review" => ReviewOutcome.to_map(review_outcome)
          }
        })

      {:review_deferred, result} ->
        success_response(result)

      {:handoff_deferred, result} ->
        success_response(result)

      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp maybe_run_before_handoff_gate(query, variables, opts, linear_client) do
    context = Keyword.get(opts, :handoff_gate_context)

    cond do
      !issue_update_mutation?(query) ->
        :ok

      !is_map(context) ->
        :ok

      true ->
        resolve_and_run_before_handoff_gate(query, variables, context, linear_client)
    end
  end

  defp resolve_and_run_before_handoff_gate(query, variables, context, linear_client) do
    issue = Map.get(context, :issue) || Map.get(context, "issue")
    workspace = Map.get(context, :workspace) || Map.get(context, "workspace")
    worker_host = Map.get(context, :worker_host) || Map.get(context, "worker_host")
    # AgentRunner threads the per-repo before_handoff hook command through
    # the handoff_gate_context map when multi-repo dispatch is active. When
    # absent, HandoffGate falls back to the host-level Config setting.
    before_handoff_cmd =
      Map.get(context, :before_handoff_command) || Map.get(context, "before_handoff_command")

    handoff_opts =
      [async: true]
      |> maybe_put_keyword(:hook_command, before_handoff_cmd)
      |> maybe_put_keyword(
        :timeout_ms,
        Map.get(context, :before_handoff_timeout_ms) || Map.get(context, "before_handoff_timeout_ms")
      )
      |> maybe_put_keyword(
        :stale_ms,
        Map.get(context, :before_handoff_stale_ms) || Map.get(context, "before_handoff_stale_ms")
      )

    with %{id: context_issue_id} when is_binary(context_issue_id) <- issue,
         workspace when is_binary(workspace) <- workspace,
         issue_id when is_binary(issue_id) <- transition_issue_id(query, variables),
         true <- transition_matches_context_issue?(issue, issue_id),
         {:ok, current_state, target_state} <-
           resolve_transition_states(query, variables, issue, issue_id, linear_client),
         true <- HandoffGate.handoff_transition?(current_state, target_state) do
      gate_issue = issue_with_state(issue, current_state)

      case revalidate_base_before_handoff(workspace, gate_issue, worker_host, context) do
        {:ok, base_drift_decision} ->
          context = put_base_drift_decision(context, base_drift_decision)

          run_resolved_handoff_gate(
            %{
              query: query,
              variables: variables,
              workspace: workspace,
              issue: gate_issue,
              worker_host: worker_host,
              target_state: target_state,
              context: context,
              linear_client: linear_client
            },
            handoff_opts
          )

        {:base_drift_blocked, _prompt, _decision} = blocked ->
          blocked
      end
    else
      _ -> :ok
    end
  end

  defp run_resolved_handoff_gate(request, handoff_opts) do
    result =
      HandoffGate.run_before_handoff(
        request.workspace,
        request.issue,
        request.worker_host,
        request.target_state,
        handoff_opts
      )

    case result do
      :ok -> run_review_gate_for_request(request)
      {:passed, _gate} -> run_review_gate_for_request(request)
      {:pending, gate} -> defer_handoff_gate(request, gate)
      {:blocked, prompt, gates} -> {:handoff_blocked, prompt, gates}
      {:failed, prompt, gate} -> {:handoff_blocked, prompt, protocol_gate_list(gate)}
      {:invalidated, prompt, gate} -> {:handoff_blocked, prompt, protocol_gate_list(gate)}
      {:infrastructure_error, prompt, gate} -> {:handoff_infrastructure_error, prompt, gate}
    end
  end

  defp run_review_gate_for_request(request) do
    run_review_gate(
      request.query,
      request.variables,
      request.workspace,
      request.issue,
      request.worker_host,
      request.context,
      request.linear_client
    )
  end

  defp defer_handoff_gate(request_context, gate) do
    context = request_context.context

    request = %{
      query: request_context.query,
      variables: request_context.variables,
      workspace: request_context.workspace,
      issue: request_context.issue,
      worker_host: request_context.worker_host,
      target_state: request_context.target_state,
      gate: gate,
      before_handoff_command: Map.get(context, :before_handoff_command) || Map.get(context, "before_handoff_command"),
      before_handoff_timeout_ms: Map.get(context, :before_handoff_timeout_ms) || Map.get(context, "before_handoff_timeout_ms"),
      before_handoff_stale_ms: Map.get(context, :before_handoff_stale_ms) || Map.get(context, "before_handoff_stale_ms"),
      review_workflow: Map.get(context, :review_workflow) || Map.get(context, "review_workflow"),
      review_opts: Map.get(context, :review_opts, []),
      linear_client: request_context.linear_client
    }

    case deferred_handoff_gate_callback(context) do
      callback when is_function(callback, 1) ->
        case callback.(request) do
          result when result in [:ok, :already_pending] ->
            {:handoff_deferred, deferred_handoff_gate_result(request_context.issue, gate)}

          {:error, reason} ->
            prompt = "Symphony could not persist pending handoff gate #{gate.job_id}: #{inspect(reason)}"
            {:handoff_infrastructure_error, prompt, gate}
        end

      _ ->
        prompt = "Symphony has no durable asynchronous handoff callback for pending gate #{gate.job_id}."
        {:handoff_infrastructure_error, prompt, gate}
    end
  end

  defp deferred_handoff_gate_callback(context) do
    Map.get(context, :deferred_handoff_gate_callback) ||
      Map.get(context, "deferred_handoff_gate_callback")
  end

  defp notify_handoff_infrastructure_failure(opts, prompt, gate) do
    context = Keyword.get(opts, :handoff_gate_context, %{})

    case Map.get(context, :handoff_infrastructure_failure_callback) ||
           Map.get(context, "handoff_infrastructure_failure_callback") do
      callback when is_function(callback, 2) -> callback.(prompt, gate)
      _callback -> :ok
    end
  end

  defp deferred_handoff_gate_result(issue, gate) do
    %{
      "success" => true,
      "status" => "handoff_gate_pending",
      "issueIdentifier" =>
        Map.get(issue, :identifier) || Map.get(issue, "identifier") || Map.get(issue, :id) ||
          Map.get(issue, "id"),
      "gate" => %{
        "jobId" => gate.job_id,
        "status" => to_string(gate.status),
        "candidateHash" => gate.candidate_hash,
        "nextPollMs" => gate.next_poll_ms,
        "progress" => gate.progress
      },
      "instructions" => "Symphony is polling the exact-candidate handoff gate outside the model turn. Do not retry the Linear mutation; end this turn now."
    }
  end

  defp protocol_gate_list(gate) do
    [
      %{
        name: "before_handoff",
        status: to_string(gate.status),
        passed: false,
        detail: gate.remediation || gate.summary
      }
    ]
  end

  defp protocol_gate_payload(%{job_id: job_id, status: status} = gate) do
    %{
      "jobId" => job_id,
      "status" => to_string(status),
      "candidateHash" => Map.get(gate, :candidate_hash),
      "exactHash" => Map.get(gate, :exact_hash),
      "identity" => Map.get(gate, :identity),
      "heartbeatAt" => Map.get(gate, :heartbeat_at),
      "heartbeatAgeMs" => Map.get(gate, :heartbeat_age_ms),
      "nextPollMs" => Map.get(gate, :next_poll_ms),
      "progress" => Map.get(gate, :progress)
    }
  end

  defp protocol_gate_payload(gate) when is_map(gate), do: gate

  defp maybe_put_keyword(opts, _key, nil), do: opts
  defp maybe_put_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  defp revalidate_base_before_handoff(workspace, issue, worker_host, context) do
    review_opts = Map.get(context, :review_opts, [])
    base_ref = Keyword.get(review_opts, :base_drift_ref)

    case BaseDrift.assess(workspace, issue, base_ref, base_drift_opts(worker_host, review_opts)) do
      {:ok, decision} ->
        {:ok, decision}

      {:defer, prompt, decision} ->
        {:base_drift_blocked, prompt, decision}

      {:error, reason} when is_binary(base_ref) ->
        prompt =
          "Symphony could not revalidate origin/#{base_ref} before final gates (#{inspect(reason)}). " <>
            "Keep the issue in progress, restore base visibility, and re-attempt the handoff. No rebase was attempted."

        {:base_drift_blocked, prompt, %{action: "defer_check_unavailable", base_ref: base_ref, reason: inspect(reason), gates_avoided: 1}}
    end
  end

  defp base_drift_opts(worker_host, review_opts) do
    [worker_host: worker_host]
    |> maybe_put_base_drift_runner(:git_runner, Keyword.get(review_opts, :base_drift_git_runner))
    |> maybe_put_base_drift_runner(:ssh_runner, Keyword.get(review_opts, :base_drift_ssh_runner))
  end

  defp maybe_put_base_drift_runner(opts, key, runner) when is_function(runner),
    do: Keyword.put(opts, key, runner)

  defp maybe_put_base_drift_runner(opts, _key, _runner), do: opts

  defp put_base_drift_decision(context, decision) do
    review_opts = context |> Map.get(:review_opts, []) |> Keyword.put(:base_drift_decision, decision)
    Map.put(context, :review_opts, review_opts)
  end

  defp issue_with_state(%SymphonyElixir.Linear.Issue{} = issue, state) when is_binary(state) do
    %{issue | state: state}
  end

  defp issue_with_state(issue, _state), do: issue

  defp transition_matches_context_issue?(issue, issue_id) when is_binary(issue_id) do
    issue_id in [
      Map.get(issue, :id) || Map.get(issue, "id"),
      Map.get(issue, :identifier) || Map.get(issue, "identifier")
    ]
  end

  # After the deterministic before_handoff shell hook passes, run the full
  # reviewer agent when the consumer repo ships a WORKFLOW_REVIEW.md
  # (AgentRunner threads the loaded review workflow through the gate context).
  # A request-changes verdict blocks the handoff with the reviewer's comments
  # as remediation, reusing the same loop the shell hook uses.
  defp run_review_gate(query, variables, workspace, issue, worker_host, context, linear_client) do
    case Map.get(context, :review_workflow) || Map.get(context, "review_workflow") do
      review_workflow when is_map(review_workflow) ->
        review_workflow
        |> review_gate_request(query, variables, workspace, issue, worker_host, context, linear_client)
        |> maybe_defer_or_run_review_gate()

      _ ->
        :ok
    end
  end

  defp review_gate_request(review_workflow, query, variables, workspace, issue, worker_host, context, linear_client) do
    # `:review_opts` is an optional passthrough (test/extensibility seam):
    # the gate always pins `linear_client`; callers may add a custom
    # session_runner / comment_fn.
    review_opts =
      context
      |> Map.get(:review_opts, [])
      |> Keyword.put(:linear_client, linear_client)

    %{
      query: query,
      variables: variables,
      workspace: workspace,
      issue: issue,
      worker_host: worker_host,
      review_workflow: review_workflow,
      review_opts: review_opts,
      context: context,
      linear_client: linear_client
    }
  end

  defp maybe_defer_or_run_review_gate(
         %{
           workspace: workspace,
           issue: issue,
           worker_host: worker_host,
           review_workflow: review_workflow,
           review_opts: review_opts,
           context: context
         } = request
       ) do
    case deferred_review_callback(context) do
      callback when is_function(callback, 1) ->
        callback.(%{
          query: request.query,
          variables: request.variables,
          workspace: workspace,
          issue: issue,
          worker_host: worker_host,
          review_workflow: review_workflow,
          review_opts: review_opts,
          linear_client: request.linear_client
        })

        {:review_deferred, deferred_review_result(issue)}

      nil ->
        run_inline_review(request)
    end
  end

  defp run_inline_review(request) do
    {review_key, pinned_opts} =
      ReviewGate.prepare_review(request.workspace, request.issue, request.review_opts)

    result =
      ReviewGate.run(
        request.workspace,
        request.issue,
        request.worker_host,
        request.review_workflow,
        pinned_opts
      )

    handle_inline_review_result(result, request, review_key, pinned_opts)
  end

  defp handle_inline_review_result(
         {:approved, review_outcome},
         request,
         review_key,
         pinned_opts
       ) do
    if ReviewGate.authoritative_for_current_head?(
         request.workspace,
         request.issue,
         review_key,
         pinned_opts,
         review_outcome
       ) do
      :ok
    else
      block_stale_approval(review_outcome)
    end
  end

  defp handle_inline_review_result(
         {:request_changes, prompt, review_outcome},
         _request,
         _review_key,
         _pinned_opts
       ) do
    {:review_blocked, prompt, review_outcome.findings, review_outcome}
  end

  defp handle_inline_review_result(
         {terminal_outcome, %ReviewOutcome{} = review_outcome},
         _request,
         _review_key,
         _pinned_opts
       )
       when terminal_outcome in [
              :automation_inconclusive,
              :infrastructure_unavailable,
              :budget_exhausted_with_findings
            ] do
    {:review_blocked, review_outcome_remediation(review_outcome), review_outcome.findings, review_outcome}
  end

  defp block_stale_approval(review_outcome) do
    stale = %{
      review_outcome
      | outcome: :automation_inconclusive,
        authoritative: false,
        failure_reason: :review_head_unpinned_or_changed,
        resume_condition: "Pin and re-review the exact current candidate SHA before applying the handoff."
    }

    {:review_blocked, review_outcome_remediation(stale), stale.findings, stale}
  end

  defp review_outcome_remediation(%ReviewOutcome{} = outcome) do
    """
    Automated review outcome: `#{outcome.outcome}` (not approved).
    Reviewed candidate SHA: `#{outcome.reviewed_sha || "unavailable"}`.
    Review iteration: #{outcome.iteration} of #{outcome.max_iterations}.
    Failure reason: `#{inspect(outcome.failure_reason)}`.

    The Linear handoff mutation was not applied. #{outcome.resume_condition}
    """
    |> String.trim()
  end

  defp deferred_review_callback(context) do
    Map.get(context, :deferred_review_callback) || Map.get(context, "deferred_review_callback")
  end

  defp deferred_review_result(issue) do
    %{
      "success" => true,
      "status" => "deferred_review_started",
      "issueIdentifier" =>
        Map.get(issue, :identifier) || Map.get(issue, "identifier") || Map.get(issue, :id) ||
          Map.get(issue, "id"),
      "review" => %{"deferred" => true},
      "instructions" => deferred_review_prompt(issue)
    }
  end

  defp deferred_review_prompt(issue) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier") || "this issue"

    """
    System message:

    Symphony accepted the In Progress -> In Review handoff request for #{identifier}, and will run the required automated reviewer outside this active tool call.

    Do not retry the Linear handoff mutation in this turn. End the turn now. Symphony will either move the issue to In Review after reviewer approval, or continue you with reviewer findings if changes are requested.
    """
    |> String.trim()
  end

  defp issue_update_mutation?(query) when is_binary(query) do
    String.contains?(query, "issueUpdate")
  end

  defp transition_issue_id(query, variables) do
    variable_string(variables, ["issueId", "id"]) || literal_argument(query, "id")
  end

  defp resolve_transition_states(query, variables, issue, issue_id, linear_client) do
    current_state = Map.get(issue, :state) || Map.get(issue, "state")
    target_state = explicit_target_state(query, variables)

    cond do
      is_binary(target_state) ->
        {:ok, current_state, target_state}

      state_id = transition_state_id(query, variables) ->
        resolve_state_id_transition(issue_id, state_id, current_state, linear_client)

      true ->
        {:error, :missing_target_state}
    end
  end

  defp explicit_target_state(query, variables) do
    variable_string(variables, ["stateName", "state", "status"]) ||
      variable_string(input_variables(variables), ["stateName", "state", "status"]) ||
      literal_argument(query, "stateName") ||
      literal_argument(query, "state") ||
      literal_argument(query, "status")
  end

  defp transition_state_id(query, variables) do
    variable_string(variables, ["stateId"]) ||
      variable_string(input_variables(variables), ["stateId"]) ||
      literal_argument(query, "stateId")
  end

  defp resolve_state_id_transition(issue_id, state_id, fallback_current_state, linear_client) do
    case linear_client.(@issue_transition_query, %{"issueId" => issue_id}, []) do
      {:ok, response} ->
        issue = get_in(response, ["data", "issue"]) || %{}
        current_state = get_in(issue, ["state", "name"]) || fallback_current_state

        target_state =
          issue
          |> get_in(["team", "states", "nodes"])
          |> find_state_name(state_id)

        if is_binary(target_state) do
          {:ok, current_state, target_state}
        else
          {:error, :target_state_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_state_name(states, state_id) when is_list(states) and is_binary(state_id) do
    Enum.find_value(states, fn
      %{"id" => ^state_id, "name" => name} when is_binary(name) -> name
      %{id: ^state_id, name: name} when is_binary(name) -> name
      _ -> nil
    end)
  end

  defp find_state_name(_states, _state_id), do: nil

  defp variable_string(variables, keys) when is_map(variables) do
    Enum.find_value(keys, fn key ->
      case Map.get(variables, key) || Map.get(variables, String.to_atom(key)) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp input_variables(variables) when is_map(variables) do
    case Map.get(variables, "input") || Map.get(variables, :input) do
      input when is_map(input) -> input
      _ -> %{}
    end
  end

  defp literal_argument(query, field) when is_binary(query) and is_binary(field) do
    pattern = ~r/#{Regex.escape(field)}\s*:\s*"([^"]+)"/

    case Regex.run(pattern, query) do
      [_match, value] -> value
      _ -> nil
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    dynamic_tool_response(not graphql_errors?(response), encode_payload(response))
  end

  defp graphql_errors?(%{"errors" => errors}) when is_list(errors) and errors != [], do: true
  defp graphql_errors?(%{errors: errors}) when is_list(errors) and errors != [], do: true
  defp graphql_errors?(_response), do: false

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp success_response(payload) do
    dynamic_tool_response(true, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `tracker.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
