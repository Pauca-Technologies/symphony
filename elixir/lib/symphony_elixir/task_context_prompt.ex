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
    comments =
      case issue.comments do
        [] -> "No Linear comments were present at dispatch."
        comments -> Enum.with_index(comments, 1) |> Enum.map_join("\n\n", &format_comment/1)
      end

    """
    ## Current Linear activity

    This bounded activity snapshot was fetched immediately before this agent session. Treat human decisions and clarifications as task input.

    #{blocked_resume_guidance(issue)}

    #{comments}
    #{truncated_comments_guidance(issue)}
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

  defp format_comment({%Comment{} = comment, index}) do
    """
    <linear-comment index="#{index}" id="#{format_attribute(comment.id || "unknown")}" author="#{format_attribute(comment.author_name || "unknown")}" created-at="#{format_datetime(comment.created_at)}" updated-at="#{format_datetime(comment.updated_at)}">
    #{comment.body}
    </linear-comment>
    """
    |> String.trim()
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
