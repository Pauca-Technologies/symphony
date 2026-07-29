defmodule SymphonyElixir.IssueActivityPrompt do
  @moduledoc """
  Renders tracker comments as required first-turn task context.
  """

  alias SymphonyElixir.Linear.{Comment, Issue}

  @spec render(Issue.t()) :: String.t() | nil
  def render(%Issue{comments: [], comments_truncated: false}), do: nil

  def render(%Issue{} = issue) do
    comments =
      issue.comments
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {comment, index} -> format_comment(comment, index) end)

    """
    Symphony-captured Linear activity:

    - This activity was fetched immediately before the outer agent session. Read it before acting; human decisions and clarifications are task input.
    #{blocked_resume_guidance(issue)}
    #{comments}
    #{truncated_comments_guidance(issue)}
    """
    |> String.trim()
  end

  defp format_comment(%Comment{} = comment, index) do
    """
    <linear-comment index="#{index}" id="#{format_attribute(comment.id || "unknown")}" author="#{format_attribute(comment.author_name || "unknown")}" created-at="#{format_datetime(comment.created_at)}" updated-at="#{format_datetime(comment.updated_at)}">
    #{comment.body}
    </linear-comment>
    """
    |> String.trim()
  end

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
      "- This issue is marked `needs-human-input`. Reconcile the human response after the blocker into the workpad before any repository work. Remove the label only after consuming that response."
    else
      "- Reconcile any human-authored update that changes scope, requirements, or the next action into the workpad."
    end
  end

  defp truncated_comments_guidance(%Issue{comments_truncated: true}) do
    "Earlier Linear comments were omitted from this bounded snapshot. Use `linear_graphql` for older activity only if the injected comments and workpad do not establish the required context."
  end

  defp truncated_comments_guidance(_issue), do: ""
end
