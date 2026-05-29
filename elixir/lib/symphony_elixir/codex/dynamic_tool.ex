defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{HandoffGate, Linear.Client, ReviewGate}

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
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
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

      {:review_blocked, prompt, findings} ->
        failure_response(%{
          "error" => %{
            "message" => "Automated reviewer requested changes before the In Review handoff.",
            "remediation" => prompt,
            "findings" => findings
          }
        })

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
      if is_binary(before_handoff_cmd), do: [hook_command: before_handoff_cmd], else: []

    with %{id: context_issue_id} <- issue,
         workspace when is_binary(workspace) <- workspace,
         issue_id when is_binary(issue_id) <- transition_issue_id(query, variables),
         true <- issue_id == context_issue_id,
         {:ok, current_state, target_state} <-
           resolve_transition_states(query, variables, issue, issue_id, linear_client),
         true <- HandoffGate.handoff_transition?(current_state, target_state) do
      case HandoffGate.run_before_handoff(workspace, issue, worker_host, target_state, handoff_opts) do
        :ok -> run_review_gate(workspace, issue, worker_host, context, linear_client)
        {:blocked, prompt, gates} -> {:handoff_blocked, prompt, gates}
      end
    else
      _ -> :ok
    end
  end

  # After the deterministic before_handoff shell hook passes, run the full
  # reviewer agent when the consumer repo ships a WORKFLOW_REVIEW.md
  # (AgentRunner threads the loaded review workflow through the gate context).
  # A request-changes verdict blocks the handoff with the reviewer's comments
  # as remediation, reusing the same loop the shell hook uses.
  defp run_review_gate(workspace, issue, worker_host, context, linear_client) do
    case Map.get(context, :review_workflow) || Map.get(context, "review_workflow") do
      review_workflow when is_map(review_workflow) ->
        # `:review_opts` is an optional passthrough (test/extensibility seam):
        # the gate always pins `linear_client`; callers may add a custom
        # session_runner / comment_fn.
        review_opts =
          context
          |> Map.get(:review_opts, [])
          |> Keyword.put(:linear_client, linear_client)

        case ReviewGate.run(workspace, issue, worker_host, review_workflow, review_opts) do
          :ok -> :ok
          {:blocked, prompt, findings} -> {:review_blocked, prompt, findings}
        end

      _ ->
        :ok
    end
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
      literal_argument(query, "stateName") ||
      literal_argument(query, "state") ||
      literal_argument(query, "status")
  end

  defp transition_state_id(query, variables) do
    variable_string(variables, ["stateId"]) || literal_argument(query, "stateId")
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
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
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
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
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
