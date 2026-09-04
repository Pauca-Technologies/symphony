defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, PromptSection, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    build_section(issue, opts).content
  end

  @doc "Render the repository workflow as a provenance-aware prompt section."
  @spec build_section(SymphonyElixir.Linear.Issue.t(), keyword()) :: PromptSection.t()
  def build_section(issue, opts \\ []) do
    # When AgentRunner has loaded a per-repo workflow (multi-repo dispatch,
    # T27), it threads the consumer's WORKFLOW.md through as
    # `:per_repo_workflow`. That workflow's `prompt_template` wins so the
    # agent sees the repo-specific instructions (UDP's "in a fresh clone
    # of udp-dashboard-v2…") rather than the generic host prompt.
    source =
      case Keyword.get(opts, :per_repo_workflow) do
        %{prompt_template: pt} = wf when is_binary(pt) ->
          {:ok, wf}

        _ ->
          Workflow.current()
      end

    template =
      source
      |> prompt_template!()
      |> parse_template!()

    content =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue |> Map.from_struct() |> to_solid_map()
        },
        @render_opts
      )
      |> IO.iodata_to_binary()

    PromptSection.new(
      id: "repository.workflow",
      type: :repository_rules,
      source: Keyword.get(opts, :workflow_source, "repository:WORKFLOW.md"),
      version: "workflow-template/v1",
      content: content,
      reusable: true,
      ownership: :repository
    )
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
