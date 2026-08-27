defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{
    BaseDrift,
    HandoffGate,
    Linear.Client,
    ReviewGate,
    ReviewOutcome,
    Tracker,
    WaitCondition
  }

  alias SymphonyElixir.Linear.{Comment, Issue}

  @linear_issue_tool "linear_issue"
  @linear_graphql_tool "linear_graphql"
  @wait_for_tool "wait_for"
  @human_blocker_kinds [
    "missing_required_tool",
    "missing_authentication",
    "missing_permission",
    "product_decision"
  ]
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
  @typed_state_lookup_query """
  query SymphonyResolveTypedState($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """
  @typed_transition_mutation """
  mutation SymphonyTypedIssueTransition($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """
  @linear_issue_description """
  Read or update the current Linear issue through typed operations. Use this for activity, the single `## Codex Workpad`, labels, workflow transitions, and separate follow-up issues for valuable discoveries outside current scope. Follow-ups are created unassigned in Backlog, in the same project, without automation labels, and linked deterministically to the current issue. Transitions to review states still run Symphony's before_handoff and automated review gates. Use `linear_graphql` only when no typed operation fits.
  """
  @linear_issue_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["operation"],
    "properties" => %{
      "operation" => %{
        "type" => "string",
        "enum" => ["get", "update_workpad", "add_label", "remove_label", "create_follow_up", "transition"]
      },
      "body" => %{
        "type" => ["string", "null"],
        "description" => "Complete workpad body beginning with `## Codex Workpad`."
      },
      "label" => %{"type" => ["string", "null"]},
      "state" => %{"type" => ["string", "null"]},
      "title" => %{"type" => ["string", "null"], "minLength" => 1},
      "description" => %{"type" => ["string", "null"], "minLength" => 1},
      "acceptance_criteria" => %{"type" => ["string", "null"], "minLength" => 1},
      "evidence" => %{"type" => ["string", "null"], "minLength" => 1},
      "depends_on_current" => %{
        "type" => ["boolean", "null"],
        "description" => "True only when the follow-up cannot start until the current issue is complete."
      },
      "blocker" => %{
        "type" => ["object", "null"],
        "additionalProperties" => false,
        "required" => ["kind", "summary"],
        "properties" => %{
          "kind" => %{"type" => "string", "enum" => @human_blocker_kinds},
          "summary" => %{"type" => "string", "minLength" => 1}
        }
      }
    }
  }
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear. In Progress to review-state issueUpdate mutations invoke Symphony's before_handoff and automated review gates. Moving the active issue to Blocked requires a top-level blocker object with a human-actionable kind and summary; Symphony, reviewer, and handoff infrastructure failures are not human blockers.
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
      },
      "blocker" => %{
        "type" => ["object", "null"],
        "description" => "Required only for a Blocked transition. Operational Symphony/reviewer/gate failures do not qualify.",
        "additionalProperties" => false,
        "required" => ["kind", "summary"],
        "properties" => %{
          "kind" => %{"type" => "string", "enum" => @human_blocker_kinds},
          "summary" => %{"type" => "string", "minLength" => 1}
        }
      }
    }
  }
  @wait_for_description """
  Park this issue without consuming an agent slot while an external GitHub, git, or Linear condition is unchanged. Never use this for local CPU or memory pressure, other validations, local process or port contention, elapsed-time backoffs, a clock, or a Symphony-owned handoff gate; Symphony persists and polls accepted handoff jobs itself. After a successful call, end the turn; Symphony persists the workspace and resumes exactly once when the external condition changes or a human resumes it.
  """
  @wait_for_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["reason", "condition"],
    "properties" => %{
      "reason" => %{"type" => "string", "minLength" => 1},
      "min_poll_seconds" => %{"type" => "integer", "minimum" => 15, "maximum" => 1_800},
      "max_poll_seconds" => %{"type" => "integer", "minimum" => 60, "maximum" => 21_600},
      "condition" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["type"],
        "properties" => %{
          "type" => %{
            "type" => "string",
            "enum" => [
              "github_actions_recovered",
              "github_pr_checks_changed",
              "github_pr_check_changed",
              "github_pr_gate_settled",
              "git_ref_changed",
              "linear_issue_changed"
            ]
          },
          "component" => %{"type" => ["string", "null"]},
          "repository" => %{"type" => ["string", "null"]},
          "pr_number" => %{"type" => ["integer", "null"], "minimum" => 1},
          "check_name" => %{"type" => ["string", "null"], "minLength" => 1},
          "ref" => %{"type" => ["string", "null"]},
          "issue_id" => %{"type" => ["string", "null"]}
        }
      }
    }
  }
  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_issue_tool ->
        execute_linear_issue(arguments, opts)

      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @wait_for_tool ->
        execute_wait_for(arguments, opts)

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
        "name" => @linear_issue_tool,
        "description" => @linear_issue_description,
        "inputSchema" => @linear_issue_input_schema
      },
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @wait_for_tool,
        "description" => @wait_for_description,
        "inputSchema" => @wait_for_input_schema
      }
    ]
  end

  defp execute_linear_issue(arguments, opts) when is_map(arguments) do
    with {:ok, operation} <- typed_operation(arguments),
         {:ok, issue} <- current_issue(opts),
         {:ok, issue_id} <- current_issue_id(issue) do
      execute_typed_issue_operation(operation, issue, issue_id, arguments, opts)
    else
      {:error, reason} -> failure_response(linear_issue_error(reason))
    end
  end

  defp execute_linear_issue(_arguments, _opts),
    do: failure_response(linear_issue_error(:invalid_arguments))

  defp execute_typed_issue_operation("get", _issue, issue_id, _arguments, opts) do
    fetch_issue = Keyword.get(opts, :tracker_fetch_issue, &Tracker.fetch_issue_states_by_ids/1)
    fetch_comments = Keyword.get(opts, :tracker_fetch_comments, &Tracker.fetch_issue_comments/1)

    with {:ok, [issue | _]} <- fetch_issue.([issue_id]),
         {:ok, %{comments: comments, truncated: truncated}} <- fetch_comments.(issue_id) do
      success_response(%{
        "issue" => typed_issue_payload(issue),
        "activity" => %{
          "comments" => Enum.map(comments, &typed_comment_payload/1),
          "truncated" => truncated
        }
      })
    else
      {:ok, []} -> failure_response(linear_issue_error(:issue_not_found))
      {:error, reason} -> failure_response(linear_issue_error(reason))
      other -> failure_response(linear_issue_error({:invalid_tracker_response, other}))
    end
  end

  defp execute_typed_issue_operation("update_workpad", _issue, issue_id, arguments, opts) do
    update_workpad = Keyword.get(opts, :tracker_update_workpad, &Tracker.update_workpad/2)

    with {:ok, body} <- typed_workpad_body(arguments),
         :ok <- update_workpad.(issue_id, body) do
      success_response(%{"status" => "updated", "operation" => "update_workpad"})
    else
      {:error, reason} -> failure_response(linear_issue_error(reason))
      other -> failure_response(linear_issue_error({:workpad_update_failed, other}))
    end
  end

  defp execute_typed_issue_operation(operation, _issue, issue_id, arguments, opts)
       when operation in ["add_label", "remove_label"] do
    label_operation =
      case operation do
        "add_label" -> Keyword.get(opts, :tracker_add_label, &Tracker.add_label/2)
        "remove_label" -> Keyword.get(opts, :tracker_remove_label, &Tracker.remove_label/2)
      end

    with {:ok, label} <- typed_non_blank(arguments, "label", :missing_label),
         :ok <- label_operation.(issue_id, label) do
      success_response(%{"status" => "updated", "operation" => operation, "label" => label})
    else
      {:error, reason} -> failure_response(linear_issue_error(reason))
      other -> failure_response(linear_issue_error({:label_update_failed, other}))
    end
  end

  defp execute_typed_issue_operation("create_follow_up", issue, _issue_id, arguments, opts) do
    create_follow_up = Keyword.get(opts, :tracker_create_follow_up, &Tracker.create_follow_up/2)

    with {:ok, title} <- typed_non_blank(arguments, "title", :missing_follow_up_title),
         {:ok, description} <-
           typed_non_blank(arguments, "description", :missing_follow_up_description),
         {:ok, acceptance_criteria} <-
           typed_non_blank(
             arguments,
             "acceptance_criteria",
             :missing_follow_up_acceptance_criteria
           ),
         {:ok, evidence} <- typed_non_blank(arguments, "evidence", :missing_follow_up_evidence),
         {:ok, follow_up} <-
           create_follow_up.(issue, %{
             title: title,
             description: description,
             acceptance_criteria: acceptance_criteria,
             evidence: evidence,
             depends_on_current: typed_value(arguments, "depends_on_current") == true
           }) do
      success_response(%{
        "status" => "created",
        "operation" => "create_follow_up",
        "issue" => follow_up
      })
    else
      {:error, reason} -> failure_response(linear_issue_error(reason))
      other -> failure_response(linear_issue_error({:follow_up_create_failed, other}))
    end
  end

  defp execute_typed_issue_operation("transition", _issue, issue_id, arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, state_name} <- typed_non_blank(arguments, "state", :missing_state),
         {:ok, response} <-
           linear_client.(
             @typed_state_lookup_query,
             %{"issueId" => issue_id, "stateName" => state_name},
             []
           ),
         state_id when is_binary(state_id) <-
           get_in(response, [
             "data",
             "issue",
             "team",
             "states",
             "nodes",
             Access.at(0),
             "id"
           ]) do
      transition_arguments = %{
        "query" => @typed_transition_mutation,
        "variables" => %{"issueId" => issue_id, "stateId" => state_id}
      }

      transition_arguments =
        case Map.get(arguments, "blocker") || Map.get(arguments, :blocker) do
          blocker when is_map(blocker) -> Map.put(transition_arguments, "blocker", blocker)
          _blocker -> transition_arguments
        end

      execute_linear_graphql(transition_arguments, opts)
    else
      nil -> failure_response(linear_issue_error({:state_not_found, typed_value(arguments, "state")}))
      {:error, reason} -> failure_response(linear_issue_error(reason))
      other -> failure_response(linear_issue_error({:state_lookup_failed, other}))
    end
  end

  defp execute_wait_for(arguments, opts) do
    context = Keyword.get(opts, :wait_context, %{})
    callback = Keyword.get(opts, :wait_callback)
    observer = Keyword.get(opts, :wait_observer, &WaitCondition.observe/1)

    with {:ok, request} <- WaitCondition.normalize(arguments, context),
         {:ok, request} <- WaitCondition.capture_baseline(request, observer: observer),
         true <- is_function(callback, 1) or {:error, :wait_unavailable},
         :ok <- callback.(request) do
      success_response(%{
        "status" => "accepted",
        "message" => "The issue will be parked after this turn. End the turn now; do not poll again.",
        "conditionKey" => request.condition_key
      })
    else
      {:error, reason} ->
        failure_response(%{
          "error" => %{
            "message" => "Unable to park this issue.",
            "reason" => inspect(reason)
          }
        })

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unable to park this issue.",
            "reason" => inspect(other)
          }
        })
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         :ok <- maybe_run_before_handoff_gate(query, variables, arguments, opts, linear_client),
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

  defp maybe_run_before_handoff_gate(query, variables, arguments, opts, linear_client) do
    context = Keyword.get(opts, :handoff_gate_context)

    cond do
      !issue_update_mutation?(query) ->
        :ok

      !is_map(context) ->
        :ok

      true ->
        resolve_and_run_before_handoff_gate(query, variables, arguments, context, linear_client)
    end
  end

  defp resolve_and_run_before_handoff_gate(
         query,
         variables,
         arguments,
         context,
         linear_client
       ) do
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
           resolve_transition_states(query, variables, issue, issue_id, linear_client) do
      handle_resolved_transition(
        %{
          query: query,
          variables: variables,
          arguments: arguments,
          workspace: workspace,
          issue: issue,
          worker_host: worker_host,
          current_state: current_state,
          target_state: target_state,
          context: context,
          linear_client: linear_client
        },
        handoff_opts
      )
    else
      _ -> :ok
    end
  end

  defp handle_resolved_transition(request, handoff_opts) do
    cond do
      HandoffGate.handoff_transition?(request.current_state, request.target_state) ->
        run_handoff_transition(request, handoff_opts)

      blocked_state?(request.target_state) ->
        validate_human_blocker(request.arguments)

      true ->
        :ok
    end
  end

  defp run_handoff_transition(request, handoff_opts) do
    do_run_handoff_transition(request, handoff_opts)
  end

  defp do_run_handoff_transition(request, handoff_opts) do
    gate_issue = issue_with_state(request.issue, request.current_state)

    case revalidate_base_before_handoff(
           request.workspace,
           gate_issue,
           request.worker_host,
           request.context
         ) do
      {:ok, base_drift_decision} ->
        context = put_base_drift_decision(request.context, base_drift_decision)

        request = Map.merge(request, %{issue: gate_issue, context: context})
        run_review_before_handoff(request, handoff_opts)

      {:base_drift_blocked, _prompt, _decision} = blocked ->
        blocked
    end
  end

  defp run_review_before_handoff(request, handoff_opts) do
    case run_review_gate_for_request(request) do
      :ok ->
        run_resolved_handoff_gate(request, handoff_opts)

      {:review_approved, approval} ->
        result =
          request
          |> Map.put(:review_approval, approval)
          |> run_resolved_handoff_gate(handoff_opts)

        revalidate_inline_review_after_handoff(result, request, approval)

      other ->
        other
    end
  end

  defp revalidate_inline_review_after_handoff(:ok, request, approval) do
    if ReviewGate.authoritative_for_current_head?(
         request.workspace,
         request.issue,
         approval.review_key,
         approval.review_opts,
         approval.review_outcome
       ) do
      :ok
    else
      block_stale_approval(approval.review_outcome)
    end
  end

  defp revalidate_inline_review_after_handoff(result, _request, _approval), do: result

  defp run_with_handoff_gate_lifecycle(request, run) when is_function(run, 0) do
    gate_job_id = "inline-#{System.unique_integer([:positive, :monotonic])}"
    started_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    gate = %{
      job_id: gate_job_id,
      status: :running,
      candidate_hash: nil,
      exact_hash: nil,
      identity: %{"mode" => "inline"},
      heartbeat_at: started_at,
      heartbeat_age_ms: 0,
      next_poll_ms: nil,
      progress: %{"stage" => "before_handoff"},
      started_at: started_at
    }

    notify_handoff_gate_lifecycle(request.context, :started, %{
      gate_job_id: gate_job_id,
      gate: gate
    })

    result =
      try do
        run.()
      catch
        kind, reason ->
          notify_handoff_gate_lifecycle(request.context, :finished, %{
            gate_job_id: gate_job_id,
            outcome: :crashed
          })

          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    notify_handoff_gate_lifecycle(request.context, :finished, %{
      gate_job_id: gate_job_id,
      outcome: handoff_gate_outcome(result)
    })

    result
  end

  defp notify_handoff_gate_lifecycle(context, event, metadata) do
    case Map.get(context, :handoff_gate_lifecycle_callback) ||
           Map.get(context, "handoff_gate_lifecycle_callback") do
      callback when is_function(callback, 2) -> callback.(event, metadata)
      _callback -> :ok
    end
  end

  defp handoff_gate_outcome(result) do
    tag = if is_tuple(result), do: elem(result, 0), else: result

    Map.get(
      %{
        ok: :passed,
        handoff_blocked: :blocked,
        handoff_infrastructure_error: :infrastructure_error,
        base_drift_blocked: :base_drift_blocked,
        review_blocked: :review_blocked,
        review_deferred: :review_deferred,
        handoff_deferred: :handoff_deferred
      },
      tag,
      :completed
    )
  end

  defp blocked_state?(state) when is_binary(state),
    do: String.downcase(String.trim(state)) == "blocked"

  defp blocked_state?(_state), do: false

  defp validate_human_blocker(arguments) when is_map(arguments) do
    blocker = Map.get(arguments, "blocker") || Map.get(arguments, :blocker)

    with blocker when is_map(blocker) <- blocker,
         kind when kind in @human_blocker_kinds <-
           Map.get(blocker, "kind") || Map.get(blocker, :kind),
         summary when is_binary(summary) <-
           Map.get(blocker, "summary") || Map.get(blocker, :summary),
         true <- String.trim(summary) != "" do
      :ok
    else
      _ -> {:error, {:blocked_transition_requires_human_blocker, @human_blocker_kinds}}
    end
  end

  defp validate_human_blocker(_arguments),
    do: {:error, {:blocked_transition_requires_human_blocker, @human_blocker_kinds}}

  defp run_resolved_handoff_gate(request, handoff_opts) do
    run_with_handoff_gate_lifecycle(request, fn ->
      do_run_resolved_handoff_gate(request, handoff_opts)
    end)
  end

  defp do_run_resolved_handoff_gate(request, handoff_opts) do
    durable_request = handoff_request(request)

    case persist_starting_handoff_gate(request.context, durable_request) do
      :ok ->
        result =
          HandoffGate.run_before_handoff(
            request.workspace,
            request.issue,
            request.worker_host,
            request.target_state,
            handoff_opts
          )

        handle_resolved_handoff_gate_result(result, request, durable_request)

      {:error, reason} ->
        prompt = "Symphony could not persist the handoff attempt before starting the gate: #{inspect(reason)}"
        {:handoff_infrastructure_error, prompt, %{status: :infrastructure_error, reason: reason}}
    end
  end

  defp handle_resolved_handoff_gate_result({:pending, gate}, request, _durable_request) do
    defer_handoff_gate(request, gate)
  end

  defp handle_resolved_handoff_gate_result(
         {:infrastructure_error, prompt, gate},
         request,
         durable_request
       ) do
    if is_binary(Map.get(gate, :job_id)) do
      case clear_starting_handoff_gate(request.context, durable_request) do
        :ok ->
          {:handoff_infrastructure_error, prompt, gate}

        {:error, reason} ->
          clear_prompt = "Symphony could not clear the durable handoff attempt after the gate completed: #{inspect(reason)}"
          {:handoff_infrastructure_error, clear_prompt, %{status: :infrastructure_error, reason: reason}}
      end
    else
      {:handoff_infrastructure_error, prompt, gate}
    end
  end

  defp handle_resolved_handoff_gate_result(result, request, durable_request) do
    case clear_starting_handoff_gate(request.context, durable_request) do
      :ok ->
        handle_terminal_handoff_gate_result(result, request)

      {:error, reason} ->
        prompt = "Symphony could not clear the durable handoff attempt after the gate completed: #{inspect(reason)}"
        {:handoff_infrastructure_error, prompt, %{status: :infrastructure_error, reason: reason}}
    end
  end

  defp handle_terminal_handoff_gate_result(:ok, _request), do: :ok
  defp handle_terminal_handoff_gate_result({:passed, _gate}, _request), do: :ok

  defp handle_terminal_handoff_gate_result({:blocked, prompt, gates}, _request),
    do: {:handoff_blocked, prompt, gates}

  defp handle_terminal_handoff_gate_result({:failed, prompt, gate}, _request),
    do: {:handoff_blocked, prompt, protocol_gate_list(gate)}

  defp handle_terminal_handoff_gate_result({:invalidated, prompt, gate}, _request),
    do: {:handoff_blocked, prompt, protocol_gate_list(gate)}

  defp run_review_gate_for_request(request) do
    run_review_gate(
      request.query,
      request.variables,
      request.workspace,
      request.issue,
      request.worker_host,
      request.context,
      request.linear_client,
      handoff_request(request)
    )
  end

  defp defer_handoff_gate(request_context, gate) do
    context = request_context.context
    request = handoff_request(request_context, gate)

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

  defp handoff_request(request_context, gate \\ nil) do
    context = request_context.context

    %{
      query: request_context.query,
      variables: request_context.variables,
      workspace: request_context.workspace,
      issue: request_context.issue,
      worker_host: request_context.worker_host,
      target_state: request_context.target_state,
      before_handoff_command: context_value(context, :before_handoff_command),
      before_handoff_timeout_ms: context_value(context, :before_handoff_timeout_ms),
      before_handoff_stale_ms: context_value(context, :before_handoff_stale_ms),
      review_workflow: context_value(context, :review_workflow),
      review_opts: context_value(context, :review_opts) || [],
      linear_client: request_context.linear_client
    }
    |> maybe_put_map_value(:review_approval, Map.get(request_context, :review_approval))
    |> maybe_put_map_value(:gate, gate)
  end

  defp persist_starting_handoff_gate(context, request) do
    invoke_handoff_state_callback(context, :handoff_gate_start_callback, request)
  end

  defp clear_starting_handoff_gate(context, request) do
    invoke_handoff_state_callback(context, :handoff_gate_clear_callback, request)
  end

  defp invoke_handoff_state_callback(context, key, request) do
    case context_value(context, key) do
      callback when is_function(callback, 1) -> callback.(request)
      _callback -> :ok
    end
  end

  defp maybe_put_map_value(map, _key, nil), do: map
  defp maybe_put_map_value(map, key, value), do: Map.put(map, key, value)

  defp context_value(context, key) when is_map(context) and is_atom(key),
    do: Map.get(context, key) || Map.get(context, Atom.to_string(key))

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

    case BaseDrift.assess(
           workspace,
           issue,
           base_ref,
           base_drift_opts(worker_host, review_opts, context)
         ) do
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

  defp base_drift_opts(worker_host, review_opts, context) do
    [worker_host: worker_host]
    |> maybe_put_keyword(
      :hook_command,
      Map.get(context, :before_handoff_command) || Map.get(context, "before_handoff_command")
    )
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

  # Before the expensive before_handoff shell hook, run the full reviewer
  # agent when the consumer repo ships a WORKFLOW_REVIEW.md
  # (AgentRunner threads the loaded review workflow through the gate context).
  # A request-changes verdict blocks the handoff with the reviewer's comments
  # as remediation, reusing the same loop the shell hook uses.
  defp run_review_gate(
         query,
         variables,
         workspace,
         issue,
         worker_host,
         context,
         linear_client,
         handoff_after_review
       ) do
    case Map.get(context, :review_workflow) || Map.get(context, "review_workflow") do
      review_workflow when is_map(review_workflow) ->
        # `:review_opts` is an optional passthrough (test/extensibility seam):
        # the gate always pins `linear_client`; callers may add a custom
        # session_runner / comment_fn.
        review_opts =
          context
          |> Map.get(:review_opts, [])
          |> Keyword.put(:linear_client, linear_client)

        maybe_defer_or_run_review_gate(%{
          query: query,
          variables: variables,
          workspace: workspace,
          issue: issue,
          worker_host: worker_host,
          review_workflow: review_workflow,
          review_opts: review_opts,
          context: context,
          linear_client: linear_client,
          handoff_after_review: handoff_after_review
        })

      _ ->
        :ok
    end
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
          linear_client: request.linear_client,
          handoff_after_review: request.handoff_after_review
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
      {:review_approved,
       %{
         review_key: review_key,
         reviewed_sha: review_outcome.reviewed_sha,
         review_opts: pinned_opts,
         review_outcome: review_outcome
       }}
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

  defp tool_error_payload({:blocked_transition_requires_human_blocker, allowed_kinds}) do
    %{
      "error" => %{
        "message" =>
          "Moving an active issue to Blocked requires a structured human blocker. Symphony, reviewer, handoff, CI, and other operational failures must leave the issue active for orchestrator retry.",
        "requiredArgument" => %{
          "blocker" => %{
            "kind" => allowed_kinds,
            "summary" => "A concise description of the missing human input."
          }
        }
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

  defp tool_error_payload({:linear_api_status, status, errors}) when is_list(errors) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status,
        "graphqlErrors" => errors,
        "hint" => "Prefer `linear_issue` for current-issue reads, workpad updates, labels, and transitions. For raw GraphQL, query issues through `issue(id: ...)` rather than guessing root fields."
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

  defp typed_operation(arguments) do
    case typed_value(arguments, "operation") do
      operation
      when operation in [
             "get",
             "update_workpad",
             "add_label",
             "remove_label",
             "create_follow_up",
             "transition"
           ] ->
        {:ok, operation}

      _operation ->
        {:error, :invalid_operation}
    end
  end

  defp current_issue(opts) do
    issue =
      [:handoff_gate_context, :wait_context]
      |> Enum.find_value(fn key ->
        context = Keyword.get(opts, key, %{})
        Map.get(context, :issue) || Map.get(context, "issue")
      end)

    if is_map(issue), do: {:ok, issue}, else: {:error, :missing_issue_context}
  end

  defp current_issue_id(issue) when is_map(issue) do
    case Map.get(issue, :id) || Map.get(issue, "id") do
      issue_id when is_binary(issue_id) and issue_id != "" -> {:ok, issue_id}
      _issue_id -> {:error, :missing_issue_context}
    end
  end

  defp typed_workpad_body(arguments) do
    with {:ok, body} <- typed_non_blank(arguments, "body", :missing_workpad_body),
         true <- String.starts_with?(String.trim_leading(body), "## Codex Workpad") do
      {:ok, body}
    else
      false -> {:error, :invalid_workpad_heading}
      {:error, reason} -> {:error, reason}
    end
  end

  defp typed_non_blank(arguments, key, error) do
    case typed_value(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, error}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, error}
    end
  end

  defp typed_value(arguments, key) when is_map(arguments) do
    Map.get(arguments, key) || Map.get(arguments, String.to_atom(key))
  end

  defp typed_issue_payload(%Issue{} = issue) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description,
      "state" => issue.state,
      "labels" => issue.labels,
      "url" => issue.url,
      "updatedAt" => typed_datetime(issue.updated_at)
    }
  end

  defp typed_issue_payload(issue) when is_map(issue) do
    %{
      "id" => typed_map_value(issue, :id, "id"),
      "identifier" => typed_map_value(issue, :identifier, "identifier"),
      "title" => typed_map_value(issue, :title, "title"),
      "description" => typed_map_value(issue, :description, "description"),
      "state" => typed_map_value(issue, :state, "state"),
      "labels" => typed_map_value(issue, :labels, "labels", []),
      "url" => typed_map_value(issue, :url, "url"),
      "updatedAt" => typed_datetime(typed_map_value(issue, :updated_at, "updatedAt"))
    }
  end

  defp typed_comment_payload(%Comment{} = comment) do
    %{
      "id" => comment.id,
      "body" => comment.body,
      "author" => comment.author_name,
      "createdAt" => typed_datetime(comment.created_at),
      "updatedAt" => typed_datetime(comment.updated_at)
    }
  end

  defp typed_comment_payload(comment) when is_map(comment) do
    %{
      "id" => typed_map_value(comment, :id, "id"),
      "body" => typed_map_value(comment, :body, "body"),
      "author" => typed_map_value(comment, :author_name, "author"),
      "createdAt" => typed_datetime(typed_map_value(comment, :created_at, "createdAt")),
      "updatedAt" => typed_datetime(typed_map_value(comment, :updated_at, "updatedAt"))
    }
  end

  defp typed_map_value(map, atom_key, string_key, default \\ nil) do
    Map.get(map, atom_key) || Map.get(map, string_key) || default
  end

  defp typed_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp typed_datetime(value) when is_binary(value), do: value
  defp typed_datetime(_value), do: nil

  defp linear_issue_error(:invalid_arguments),
    do: %{"error" => %{"message" => "`linear_issue` expects an object argument."}}

  defp linear_issue_error(:invalid_operation),
    do: %{
      "error" => %{
        "message" => "Unsupported `linear_issue` operation.",
        "supportedOperations" => [
          "get",
          "update_workpad",
          "add_label",
          "remove_label",
          "create_follow_up",
          "transition"
        ]
      }
    }

  defp linear_issue_error(:missing_issue_context),
    do: %{
      "error" => %{
        "message" => "`linear_issue` is available only inside a Symphony issue session."
      }
    }

  defp linear_issue_error(:invalid_workpad_heading),
    do: %{
      "error" => %{
        "message" => "The workpad body must begin with `## Codex Workpad`."
      }
    }

  defp linear_issue_error(reason),
    do: %{
      "error" => %{
        "message" => "The typed Linear issue operation failed.",
        "reason" => inspect(reason),
        "hint" => "Use `linear_graphql` only if the required operation is not available through `linear_issue`."
      }
    }

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
