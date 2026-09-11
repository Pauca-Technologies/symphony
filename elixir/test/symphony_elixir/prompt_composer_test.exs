defmodule SymphonyElixir.PromptComposerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.{Comment, Issue}
  alias SymphonyElixir.{PromptComposer, PromptSection, TaskContextPrompt}

  @issue_body """
  Implement the compact prompt composer.

  Acceptance criteria:
  - Preserve repository validation.
  - Preserve tenant and authorization safety.
  """

  test "canonical task context owns exact repeated issue prose without losing distinct constraints" do
    issue = issue(@issue_body)

    workflow =
      section(
        "repository.workflow",
        """
        Work on the following issue:

        #{@issue_body}

        Repository-only safety: never cross tenant boundaries.
        Validation: run make all before handoff.
        Handoff: keep the issue active if validation fails.
        """
      )

    composition =
      PromptComposer.compose(TaskContextPrompt.sections(issue) ++ [workflow],
        canonical_fragments: TaskContextPrompt.canonical_fragments(issue)
      )

    assert occurrences(composition.prompt, String.trim(@issue_body)) == 1
    assert composition.prompt =~ "never cross tenant boundaries"
    assert composition.prompt =~ "run make all before handoff"
    assert composition.prompt =~ "keep the issue active if validation fails"

    assert [%{decision: "suppressed", reason: "canonical_exact_duplicate"}] =
             Enum.map(composition.decisions, &Map.take(&1, [:decision, :reason]))

    workflow_metadata = Enum.find(composition.sections, &(&1.id == "repository.workflow"))
    assert workflow_metadata.source == "repository:WORKFLOW.md"
    assert workflow_metadata.version == "fixture/v1"
    assert workflow_metadata.bytes > 0
    assert workflow_metadata.estimated_tokens > 0
    assert byte_size(workflow_metadata.hash) == 64
  end

  test "formatting-only rule duplicates are removed only with explicit canonical provenance" do
    repository = section("repository.workflow", "* Run make all before handoff and preserve every validation failure.")

    composition =
      PromptComposer.compose([repository],
        canonical_fragments: [
          %{
            id: "symphony.validation_handoff",
            content: "- Run make all before handoff and preserve every validation failure.",
            authoritative_section_id: "symphony.validation_handoff",
            source_section_ids: ["repository.workflow"]
          }
        ]
      )

    refute composition.prompt =~ "* Run make all"
    assert composition.prompt =~ "symphony.validation_handoff"
    assert Enum.any?(composition.decisions, &(&1.reason == "canonical_format_equivalent_duplicate"))
  end

  test "similar but distinct safety instructions fail open and emit an ambiguous diagnostic" do
    distinct =
      "Run tenant authentication validation before every handoff and preserve all failures for explicit human review."

    canonical =
      "Run tenant authentication validation before every handoff and preserve all failures for mandatory human review."

    composition =
      PromptComposer.compose([section("repository.workflow", distinct)],
        canonical_fragments: [
          %{
            id: "symphony.security_handoff",
            content: canonical,
            authoritative_section_id: "symphony.security_handoff",
            source_section_ids: ["repository.workflow"]
          }
        ]
      )

    assert composition.prompt == distinct
    assert composition.decisions == []

    assert composition.diagnostics == [
             %{
               section_id: "repository.workflow",
               canonical_fragment_id: "symphony.security_handoff",
               decision: "preserved",
               reason: "ambiguous_overlap"
             }
           ]
  end

  test "continuation reuse distinguishes unchanged static context from changed current metadata" do
    issue = issue(@issue_body)
    initial = PromptComposer.compose(TaskContextPrompt.sections(issue))

    changed = %{issue | state: "Blocked", updated_at: ~U[2026-08-02 12:00:00Z]}
    changed_sections = TaskContextPrompt.sections(changed)
    {reused, changed_sections} = PromptComposer.reused_sections(initial.state, changed_sections)

    assert Enum.map(reused, & &1.id) == ["task.issue", "task.activity"]
    assert Enum.map(changed_sections, & &1.id) == ["task.current_metadata"]
    assert hd(changed_sections).content =~ "State: Blocked"
  end

  test "continuation comparison includes changed activity while reusing unchanged metadata" do
    issue = issue(@issue_body)
    initial = PromptComposer.compose(TaskContextPrompt.sections(issue))

    changed = %{
      issue
      | comments: [
          %Comment{
            id: "new-comment",
            body: "New decision: keep the tenant guard.",
            author_name: "Reviewer",
            created_at: ~U[2026-08-02 11:00:00Z]
          }
        ]
    }

    current_sections =
      changed
      |> TaskContextPrompt.sections()
      |> Enum.filter(&(&1.id in ["task.current_metadata", "task.activity"]))

    {reused, changed_sections} = PromptComposer.reused_sections(initial.state, current_sections)

    assert Enum.map(reused, & &1.id) == ["task.current_metadata"]
    assert Enum.map(changed_sections, & &1.id) == ["task.activity"]
    assert hd(changed_sections).content =~ "New decision: keep the tenant guard."
  end

  test "bounded debug rendering exposes boundaries while redacting configured assignments" do
    composition =
      PromptComposer.compose([
        section(
          "repository.workflow",
          """
          Authorization: Bearer bearer-secret
          api_key = simple-secret extra-text
          client_secret = "quoted secret value"
          Run validation.
          """
        )
      ])

    rendered =
      PromptComposer.debug_render(composition,
        redact_fields: ["authorization", "api_key", "client_secret"]
      )

    assert rendered =~ "SYMPHONY_PROMPT_SECTION id=repository.workflow"
    assert rendered =~ "Authorization: [REDACTED]"
    assert rendered =~ "api_key = [REDACTED]"
    assert rendered =~ "client_secret = [REDACTED]"
    assert rendered =~ "Run validation."
    refute rendered =~ "bearer-secret"
    refute rendered =~ "simple-secret"
    refute rendered =~ "extra-text"
    refute rendered =~ "quoted secret value"

    bounded =
      PromptComposer.debug_render(composition,
        redact_fields: ["authorization", "api_key", "client_secret"],
        max_bytes: 120
      )

    assert bounded =~ "prompt debug truncated sha256="
    assert byte_size(bounded) <= 120
  end

  test "fixture corpus reduces initial and fresh-retry payload without losing acceptance criteria" do
    for suffix <- ["initial", "fresh retry"] do
      issue = issue(@issue_body <> "\nCorpus marker: #{suffix}.")

      repository =
        section(
          "repository.workflow",
          """
          Repository workflow for #{suffix}:

          #{issue.description}

          Unique acceptance: run focused tests.
          Unique acceptance: preserve auth and tenant isolation.
          Unique acceptance: report unresolved findings at handoff.
          """
        )

      legacy = TaskContextPrompt.render(issue) <> "\n\n" <> repository.content

      composition =
        PromptComposer.compose(TaskContextPrompt.sections(issue) ++ [repository],
          canonical_fragments: TaskContextPrompt.canonical_fragments(issue)
        )

      assert byte_size(composition.prompt) < byte_size(legacy)
      assert composition.suppressed_bytes >= byte_size(String.trim(issue.description))
      assert composition.prompt =~ "Unique acceptance: run focused tests."
      assert composition.prompt =~ "Unique acceptance: preserve auth and tenant isolation."
      assert composition.prompt =~ "Unique acceptance: report unresolved findings at handoff."
      assert occurrences(composition.prompt, "- Preserve repository validation.") == 1
    end
  end

  defp issue(description) do
    %Issue{
      id: "issue-7166",
      identifier: "UDPE-7166",
      title: "Compose prompts with provenance",
      description: String.trim(description),
      state: "In Progress",
      labels: ["repo:symphony"],
      url: "https://linear.example/UDPE-7166",
      updated_at: ~U[2026-08-02 10:00:00Z]
    }
  end

  defp section(id, content) do
    PromptSection.new(
      id: id,
      type: :repository_rules,
      source: "repository:WORKFLOW.md",
      version: "fixture/v1",
      content: content,
      reusable: true,
      ownership: :repository
    )
  end

  defp occurrences(haystack, needle), do: length(:binary.matches(haystack, needle))
end
