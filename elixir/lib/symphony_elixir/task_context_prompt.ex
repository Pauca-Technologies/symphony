defmodule SymphonyElixir.TaskContextPrompt do
  @moduledoc """
  Renders the host-owned first-turn task context for an issue.

  The context keeps the issue snapshot, current tracker activity, and any
  repository-generated startup artifacts together before the repository
  workflow prompt.
  """

  alias SymphonyElixir.Linear.{Comment, Issue}
  alias SymphonyElixir.{PromptSection, SessionStartHook}

  @section_version "task-context/v1"
  @activity_cursor_state_key :task_activity_cursor

  @spec render(Issue.t(), SessionStartHook.result() | nil) :: String.t()
  def render(%Issue{} = issue, session_start \\ nil) do
    issue
    |> sections(session_start)
    |> Enum.map_join("\n\n", & &1.content)
  end

  @doc "Return the canonical, independently versioned task-context sections."
  @spec sections(Issue.t(), SessionStartHook.result() | nil) :: [PromptSection.t()]
  def sections(%Issue{} = issue, session_start \\ nil) do
    [
      section("task.issue", :task_issue, issue_source(issue), issue_section(issue), true, :linear),
      section(
        "task.current_metadata",
        :current_candidate_metadata,
        issue_source(issue),
        current_metadata_section(issue),
        true,
        :linear
      ),
      section("task.activity", :task_activity, activity_source(issue), activity_section(issue), true, :linear),
      section(
        "task.startup_artifacts",
        :startup_artifacts,
        "repository:session_start",
        startup_artifacts_section(session_start),
        true,
        :repository
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc "Store the current Linear activity cursor alongside prompt-composition state."
  @spec put_activity_cursor(map(), Issue.t()) :: map()
  def put_activity_cursor(state, %Issue{} = issue) when is_map(state) do
    Map.put(state, @activity_cursor_state_key, activity_cursor(issue))
  end

  @doc "Render only Linear comments added or updated since the stored activity cursor."
  @spec activity_delta_section(Issue.t(), map()) :: PromptSection.t() | nil
  def activity_delta_section(%Issue{} = issue, prior_state) when is_map(prior_state) do
    case Map.fetch(prior_state, @activity_cursor_state_key) do
      {:ok, prior_cursor} when is_map(prior_cursor) ->
        current_cursor = activity_cursor(issue)

        changed_comments =
          Enum.filter(issue.comments, fn comment ->
            Map.get(prior_cursor, activity_comment_key(comment)) != activity_comment_fingerprint(comment)
          end)

        removed_count = map_size(prior_cursor) - map_size(Map.take(prior_cursor, Map.keys(current_cursor)))

        section(
          "task.activity",
          :task_activity,
          activity_source(issue),
          activity_delta_content(issue, changed_comments, max(removed_count, 0)),
          true,
          :linear
        )

      :error ->
        nil
    end
  end

  @doc "Return a bounded identity map for the issue's current Linear comments."
  @spec activity_cursor(Issue.t()) :: map()
  def activity_cursor(%Issue{} = issue) do
    Map.new(issue.comments, fn comment ->
      {activity_comment_key(comment), activity_comment_fingerprint(comment)}
    end)
  end

  @doc "Return task fragments whose duplicate rendering outside the canonical task section may be suppressed."
  @spec canonical_fragments(Issue.t()) :: [map()]
  def canonical_fragments(%Issue{description: description}) when is_binary(description) do
    case String.trim(description) do
      "" ->
        []

      content ->
        [
          %{
            id: "task.issue.description",
            content: content,
            authoritative_section_id: "task.issue",
            source_section_ids: ["repository.workflow"],
            allow_format_equivalent: true
          }
        ]
    end
  end

  def canonical_fragments(%Issue{}), do: []

  defp issue_section(%Issue{} = issue) do
    """
    # Task context

    Issue: #{format_value(issue.identifier)}
    Title: #{format_value(issue.title)}
    Description:
    #{format_description(issue.description)}
    """
    |> String.trim()
  end

  defp current_metadata_section(%Issue{} = issue) do
    """
    ## Current candidate metadata

    State: #{format_value(issue.state)}
    Labels: #{format_labels(issue.labels)}
    URL: #{format_value(issue.url)}
    Issue updated at: #{format_datetime(issue.updated_at)}
    """
    |> String.trim()
  end

  defp activity_section(%Issue{} = issue) do
    comments = format_comments(issue.comments, "No Linear comments were present at dispatch.")

    """
    ## Current Linear activity

    This bounded activity snapshot was fetched immediately before this agent session. Treat human decisions and clarifications as task input.

    #{blocked_resume_guidance(issue)}

    #{comments}
    #{truncated_comments_guidance(issue)}
    """
    |> String.trim()
  end

  defp activity_delta_content(%Issue{} = issue, comments, removed_count) do
    comments_text =
      format_comments(
        comments,
        if(removed_count > 0,
          do: "No comments were added or updated; #{removed_count} prior comment(s) are no longer in the bounded snapshot.",
          else: "No Linear comment changed since the previous turn."
        )
      )

    removal_note =
      if removed_count > 0 and comments != [] do
        "\n#{removed_count} prior comment(s) are no longer in the bounded activity snapshot."
      else
        ""
      end

    """
    ## Linear activity since the previous turn

    Treat new human decisions and clarifications as task input. An updated workpad is the current execution state.

    #{blocked_resume_guidance(issue)}

    #{comments_text}
    #{removal_note}
    """
    |> String.trim()
  end

  defp startup_artifacts_section(nil), do: nil
  defp startup_artifacts_section(%{outcome: :skipped}), do: nil
  defp startup_artifacts_section(%{outcome: :passed, artifacts: []}), do: nil

  defp startup_artifacts_section(%{outcome: outcome, artifacts: artifacts})
       when outcome in [:passed, :failed] do
    """
    ## Startup artifacts generated for this task

    #{startup_outcome_guidance(outcome)}

    #{format_artifacts(artifacts)}
    """
    |> String.trim()
  end

  defp section(_id, _type, _source, nil, _reusable, _ownership), do: nil

  defp section(id, type, source, content, reusable, ownership) do
    PromptSection.new(
      id: id,
      type: type,
      source: source,
      version: @section_version,
      content: content,
      reusable: reusable,
      ownership: ownership
    )
  end

  defp issue_source(%Issue{id: id}) when is_binary(id), do: "linear:issue/#{id}"
  defp issue_source(%Issue{identifier: identifier}), do: "linear:issue/#{identifier || "unknown"}"

  defp activity_source(%Issue{} = issue), do: issue_source(issue) <> "/activity"

  defp startup_outcome_guidance(:passed) do
    "The repository generated these files before this turn from the workspace and issue snapshot. Read them before source; each annotation explains what it contributes."
  end

  defp startup_outcome_guidance(:failed) do
    "The repository's informational `session_start` hook failed. Continue with the task and use any artifacts it produced before failing."
  end

  defp format_artifacts([]), do: "No startup artifacts were found."

  defp format_artifacts(artifacts) do
    Enum.map_join(artifacts, "\n", fn artifact ->
      description = artifact.description || "generated by the repository's `session_start` hook"
      "- `#{artifact.path}` — #{description}."
    end)
  end

  defp format_comments([], empty_message), do: empty_message

  defp format_comments(comments, _empty_message) do
    comments
    |> compress_repeated_automation()
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", &format_comment/1)
  end

  defp format_comment({{%Comment{} = comment, repeated_count}, index}) do
    repetition =
      if repeated_count > 0 do
        "\n<linear-automation-summary omitted-equivalent-comments=\"#{repeated_count}\" />"
      else
        ""
      end

    """
    <linear-comment index="#{index}" id="#{format_attribute(comment.id || "unknown")}" author="#{format_attribute(comment.author_name || "unknown")}" created-at="#{format_datetime(comment.created_at)}" updated-at="#{format_datetime(comment.updated_at)}">
    #{comment.body}
    </linear-comment>#{repetition}
    """
    |> String.trim()
  end

  defp compress_repeated_automation(comments) do
    indexed = Enum.with_index(comments)

    grouped =
      indexed
      |> Enum.filter(fn {comment, _index} -> not is_nil(automation_group_key(comment)) end)
      |> Enum.group_by(fn {comment, _index} -> automation_group_key(comment) end)

    collapsed =
      Enum.reduce(grouped, %{}, fn {_key, entries}, acc ->
        {latest_comment, latest_index} = Enum.max_by(entries, &comment_recency/1)
        Map.put(acc, latest_index, {latest_comment, length(entries) - 1})
      end)

    indexed
    |> Enum.flat_map(fn {comment, index} ->
      cond do
        is_nil(automation_group_key(comment)) -> [{index, {comment, 0}}]
        Map.has_key?(collapsed, index) -> [{index, Map.fetch!(collapsed, index)}]
        true -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp automation_group_key(%Comment{body: body}) when is_binary(body) do
    marker =
      cond do
        String.contains?(body, "<!-- symphony:review-skipped -->") -> "review-skipped"
        String.contains?(body, "<!-- symphony:review-budget-exhausted -->") -> "review-budget-exhausted"
        true -> nil
      end

    if marker do
      {marker, capture(body, ~r/Automated review outcome: `([^`]+)`/), capture(body, ~r/Candidate SHA: `([^`]+)`/)}
    end
  end

  defp automation_group_key(_comment), do: nil

  defp capture(body, regex) do
    case Regex.run(regex, body, capture: :all_but_first) do
      [value] -> value
      _ -> "unknown"
    end
  end

  defp comment_recency({comment, index}) do
    timestamp = comment.updated_at || comment.created_at
    {if(match?(%DateTime{}, timestamp), do: DateTime.to_unix(timestamp, :microsecond), else: 0), index}
  end

  defp activity_comment_key(%Comment{id: id}) when is_binary(id) and id != "", do: id

  defp activity_comment_key(%Comment{} = comment) do
    "anonymous:" <> activity_comment_fingerprint(comment)
  end

  defp activity_comment_fingerprint(%Comment{} = comment) do
    [comment.body, comment.author_id, comment.author_name, format_datetime(comment.created_at), format_datetime(comment.updated_at)]
    |> Enum.map_join("\u0000", &to_string(&1 || ""))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp format_labels([]), do: "None"
  defp format_labels(labels) when is_list(labels), do: Enum.join(labels, ", ")

  defp format_description(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "No description provided."
      description -> description
    end
  end

  defp format_description(_value), do: "No description provided."

  defp format_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "Not provided"
      formatted -> formatted
    end
  end

  defp format_value(_value), do: "Not provided"

  defp format_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_datetime(_value), do: "unknown"

  defp format_attribute(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp blocked_resume_guidance(%Issue{labels: labels}) when is_list(labels) do
    if "needs-human-input" in labels do
      "This issue is marked `needs-human-input`. Reconcile the human response after the blocker into the workpad before repository work. Remove the label only after consuming that response."
    else
      "Reconcile any human-authored update that changes scope, requirements, or the next action into the workpad."
    end
  end

  defp truncated_comments_guidance(%Issue{comments_truncated: true}) do
    "\nEarlier Linear comments were omitted from this bounded snapshot. Use `linear_graphql` for older activity only if the task context and workpad do not establish the required context."
  end

  defp truncated_comments_guidance(_issue), do: ""
end
