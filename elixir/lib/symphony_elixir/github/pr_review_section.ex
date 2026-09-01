defmodule SymphonyElixir.Github.PrReviewSection do
  @moduledoc """
  Owns the deterministic, bounded "Review this PR" section that the reviewer
  agent's verdict drives onto the GitHub PR body.

  The reviewer agent is Linear-read-only and never edits the PR itself; instead
  it emits a `review_effort` tier (`:none | :skim | :focused | :thorough`) for
  telemetry and a structured `review_direction` value for humans. `ReviewGate`
  hands those to this module, which renders a marker-delimited section and
  upserts it into the PR body via GitHub's `updatePullRequest` GraphQL mutation.

  Determinism lives here, not in the LLM:

    * the section markers (`<!-- symphony:review:start/end -->`) and heading are
      fixed, so the region is overwritten in place every run instead of
      appended/duplicated;
    * at most three exact-head code targets and two verification items are
      rendered, so model prose cannot turn the PR body into an unbounded report;
    * code targets become exact-SHA GitHub links when PR identity is available;
    * legacy string guidance remains accepted during rollout, but is flattened
      and capped rather than copied as Markdown;
    * when the freshly-rendered block is byte-identical to what is already on
      the PR, no write happens (the "overwrite only if it thinks differently"
      contract).

  Best-effort by design, like `Github.ReviewerRequest`: a missing PR, a `gh`
  failure, or a missing token never raises and never blocks the handoff — it is
  logged and swallowed, because a PR annotation must not wedge the pipeline.
  """

  require Logger

  @marker_start "<!-- symphony:review:start -->"
  @marker_end "<!-- symphony:review:end -->"
  @default_heading "## Review this PR"
  @pr_ref_keys [:pr_ref, :pr_url]
  @max_targets 3
  @max_verifications 2
  @max_path_length 320
  @max_question_length 240
  @max_label_length 80
  @max_expectation_length 240
  @max_command_length 320
  @max_url_length 2_000
  @max_summary_length 280

  @type effort :: :none | :skim | :focused | :thorough
  @type target :: %{
          required(:path) => String.t(),
          required(:line_start) => pos_integer(),
          optional(:line_end) => pos_integer() | nil,
          required(:question) => String.t()
        }
  @type verification :: %{
          required(:label) => String.t(),
          required(:expectation) => String.t(),
          optional(:url) => String.t() | nil,
          optional(:command) => String.t() | nil
        }
  @type direction :: %{
          required(:summary) => String.t() | nil,
          required(:targets) => [target()],
          required(:verification) => [verification()]
        }
  @type pr :: %{
          required(:number) => pos_integer(),
          required(:body) => String.t(),
          optional(:id) => String.t() | nil,
          optional(:head_oid) => String.t() | nil,
          optional(:base_oid) => String.t() | nil,
          optional(:base_ref) => String.t() | nil,
          optional(:url) => String.t() | nil,
          optional(:repository) => String.t() | nil,
          optional(:is_draft) => boolean(),
          optional(:changed_files) => non_neg_integer() | nil
        }
  # (gh args, cwd) -> {output, exit_status}; mirrors Github.ReviewerRequest.
  @type runner :: ([String.t()], Path.t() -> {String.t(), non_neg_integer()})

  @doc """
  Resolve the PR via `gh pr view`.

  When `:pr_ref` / `:pr_url` is provided, it is passed to `gh pr view` first
  (for example a GitHub PR URL from the Linear attachment). Without an explicit
  reference, this falls back to the current branch in `workspace`.

  Returns `{:ok, %{number:, body:}}` or `{:skip, reason}` (no PR, unparseable
  output, or `gh` unavailable). Never raises.
  """
  @spec resolve_pr(Path.t(), keyword()) :: {:ok, pr()} | {:skip, term()}
  def resolve_pr(workspace, opts \\ []) when is_binary(workspace) do
    runner = Keyword.get(opts, :pr_runner, &default_runner/2)

    args =
      ["pr", "view"] ++
        explicit_pr_ref_args(opts) ++
        ["--json", "id,number,body,url,headRefOid,baseRefOid,baseRefName,changedFiles,headRepository,isDraft"]

    case safe_run(runner, args, workspace) do
      {output, 0} -> parse_pr(output)
      {:error, reason} -> {:skip, reason}
      {_output, _code} -> {:skip, :no_pr}
    end
  end

  @doc "Move an existing managed PR to draft and verify its exact head did not change."
  @spec ensure_draft(Path.t(), pr() | nil, keyword()) ::
          {:ok, pr()} | {:skip, :no_pr} | {:error, term()}
  def ensure_draft(_workspace, nil, _opts), do: {:skip, :no_pr}

  def ensure_draft(_workspace, %{is_draft: true} = pr, _opts), do: {:ok, pr}

  def ensure_draft(workspace, %{number: number} = pr, opts)
      when is_binary(workspace) and is_integer(number) do
    change_draft_state(workspace, pr, true, opts)
  end

  @doc "Move an approved managed PR to ready-for-review and verify its exact head."
  @spec mark_ready(Path.t(), pr() | nil, keyword()) :: {:ok, pr()} | {:error, term()}
  def mark_ready(_workspace, nil, _opts), do: {:error, :no_pr}

  def mark_ready(_workspace, %{is_draft: false} = pr, _opts), do: {:ok, pr}

  def mark_ready(workspace, %{number: number} = pr, opts)
      when is_binary(workspace) and is_integer(number) do
    change_draft_state(workspace, pr, false, opts)
  end

  @doc """
  Upsert the review section onto `pr`'s body in `workspace`.

  Returns `:written` (the PR body was edited), `:unchanged` (the section already
  matched, no write), or `:skipped` (no PR, or the `gh` update failed).
  Never raises.
  """
  @spec upsert(Path.t(), pr() | nil, effort(), term(), keyword()) :: :written | :unchanged | :skipped
  def upsert(workspace, %{number: number, body: body} = pr, effort, review_direction, opts)
      when is_binary(workspace) and is_integer(number) do
    render_opts =
      opts
      |> Keyword.put_new(:repository, Map.get(pr, :repository))
      |> Keyword.put_new(:head_oid, Map.get(pr, :head_oid))

    case normalize_direction(review_direction) do
      {:ok, direction} ->
        body_change =
          if empty_direction?(direction) do
            remove_from_body(body)
          else
            apply_to_body(body, render(effort, direction, render_opts))
          end

        case body_change do
          :unchanged -> :unchanged
          {:changed, new_body} -> write_body(workspace, pr, new_body, opts)
        end

      {:error, reason} ->
        Logger.warning("PrReviewSection invalid review direction pr=##{number} reason=#{inspect(reason)}")
        :skipped
    end
  end

  def upsert(_workspace, _pr, _risk, _review_direction, _opts), do: :skipped

  @doc """
  Render a marker-delimited section from an already-normalized direction.

  The effort tier is intentionally not displayed. It remains telemetry for
  review routing, while the visible section answers only what a human should
  inspect and which evidence to watch.
  """
  @spec render(effort(), term(), keyword()) :: String.t()
  def render(_effort, review_direction, opts \\ []) do
    heading = Keyword.get(opts, :section_heading) || @default_heading
    direction = normalize_direction!(review_direction)

    content =
      [
        escaped_summary(direction.summary),
        render_targets(direction.targets, opts),
        render_verification(direction.verification)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n\n")

    """
    #{@marker_start}
    #{heading}

    #{content}
    #{@marker_end}
    """
    |> String.trim_trailing()
  end

  @doc "Normalize and validate structured review direction, with bounded legacy-string compatibility."
  @spec normalize_direction(term()) :: {:ok, direction()} | {:error, term()}
  def normalize_direction(nil), do: {:ok, empty_direction()}

  def normalize_direction(value) when is_binary(value) do
    case bounded_text(value, @max_summary_length) do
      nil -> {:ok, empty_direction()}
      summary -> {:ok, %{empty_direction() | summary: summary}}
    end
  end

  def normalize_direction(value) when is_map(value) do
    with {:ok, summary} <- optional_text(fetch(value, :summary), @max_summary_length, :summary),
         {:ok, targets} <- normalize_targets(fetch(value, :targets)),
         {:ok, verification} <- normalize_verifications(fetch(value, :verification)) do
      {:ok, %{summary: summary, targets: targets, verification: verification}}
    end
  end

  def normalize_direction(_value), do: {:error, :review_direction_must_be_an_object}

  @doc """
  Replace the existing marker region with `block`, or insert it after the PR's
  introductory summary when absent.
  Returns `:unchanged` when the existing region already equals `block`.
  """
  @spec apply_to_body(String.t(), String.t()) :: :unchanged | {:changed, String.t()}
  def apply_to_body(body, block) when is_binary(body) and is_binary(block) do
    case Regex.run(region_regex(), body) do
      [existing] when existing == block ->
        :unchanged

      [existing] ->
        {:changed, String.replace(body, existing, block)}

      nil ->
        {:changed, insert_after_intro(body, block)}
    end
  end

  @doc "Remove the managed review region when no targeted human direction is warranted."
  @spec remove_from_body(String.t()) :: :unchanged | {:changed, String.t()}
  def remove_from_body(body) when is_binary(body) do
    case Regex.run(region_regex(), body) do
      [existing] ->
        {:changed,
         body
         |> String.replace(existing, "")
         |> String.replace(~r/\n{3,}/, "\n\n")
         |> String.trim_trailing()}

      nil ->
        :unchanged
    end
  end

  # --- internals -----------------------------------------------------------

  defp region_regex do
    ~r/#{Regex.escape(@marker_start)}.*?#{Regex.escape(@marker_end)}/s
  end

  defp explicit_pr_ref_args(opts) do
    opts
    |> Enum.find_value(fn
      {key, value} when key in @pr_ref_keys and is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          ref -> [ref]
        end

      _ ->
        nil
    end)
    |> case do
      nil -> []
      args -> args
    end
  end

  defp parse_pr(output) do
    case Jason.decode(output) do
      {:ok, %{"number" => number} = decoded} when is_integer(number) ->
        {:ok,
         %{
           id: string_or_nil(Map.get(decoded, "id")),
           number: number,
           body: string_or_empty(Map.get(decoded, "body")),
           head_oid: string_or_nil(Map.get(decoded, "headRefOid")),
           base_oid: string_or_nil(Map.get(decoded, "baseRefOid")),
           base_ref: string_or_nil(Map.get(decoded, "baseRefName")),
           url: string_or_nil(Map.get(decoded, "url")),
           repository: repository_name(Map.get(decoded, "headRepository")),
           is_draft: Map.get(decoded, "isDraft") == true,
           changed_files: integer_or_nil(Map.get(decoded, "changedFiles"))
         }}

      _ ->
        {:skip, :pr_view_unparseable}
    end
  end

  defp write_body(workspace, %{id: id, number: number}, new_body, opts) when is_binary(id) and id != "" do
    runner = Keyword.get(opts, :pr_runner, &default_runner/2)

    args = [
      "api",
      "graphql",
      "-f",
      "query=#{update_pull_request_body_mutation()}",
      "-F",
      "pullRequestId=#{id}",
      "-f",
      "body=#{new_body}"
    ]

    case safe_run(runner, args, workspace) do
      {_output, 0} ->
        :written

      {:error, reason} ->
        Logger.warning("PrReviewSection gh api graphql failed pr=##{number} reason=#{inspect(reason)}")
        :skipped

      {output, code} ->
        Logger.warning("PrReviewSection gh api graphql exit=#{code} pr=##{number} output=#{truncate(output)}")
        :skipped
    end
  end

  defp write_body(_workspace, %{number: number}, _new_body, _opts) do
    Logger.warning("PrReviewSection missing PR node id pr=##{number}; skipping review section update")
    :skipped
  end

  defp change_draft_state(workspace, %{number: number} = pr, draft?, opts) do
    runner = Keyword.get(opts, :pr_runner, &default_runner/2)
    args = ["pr", "ready", Integer.to_string(number)] ++ if(draft?, do: ["--undo"], else: [])

    case safe_run(runner, args, workspace) do
      {_output, 0} -> verify_draft_state(workspace, pr, draft?, opts)
      {:error, reason} -> {:error, {:pr_draft_state_failed, reason}}
      {output, code} -> {:error, {:pr_draft_state_failed, code, truncate(output)}}
    end
  end

  defp verify_draft_state(workspace, %{number: number, head_oid: expected_head}, draft?, opts) do
    refresh_opts =
      opts
      |> Keyword.delete(:pr_url)
      |> Keyword.put(:pr_ref, Integer.to_string(number))

    case resolve_pr(workspace, refresh_opts) do
      {:ok, %{head_oid: ^expected_head, is_draft: ^draft?} = refreshed} ->
        {:ok, refreshed}

      {:ok, %{head_oid: actual_head}} when actual_head != expected_head ->
        {:error, {:pr_head_changed, expected_head, actual_head}}

      {:ok, %{is_draft: actual}} ->
        {:error, {:pr_draft_state_not_applied, draft?, actual}}

      {:skip, reason} ->
        {:error, {:pr_refresh_failed, reason}}
    end
  end

  defp update_pull_request_body_mutation do
    """
    mutation SymphonyUpdatePullRequestBody($pullRequestId: ID!, $body: String!) {
      updatePullRequest(input: {pullRequestId: $pullRequestId, body: $body}) {
        pullRequest {
          number
        }
      }
    }
    """
  end

  # Wrap the runner so a missing `gh` binary (System.cmd raising :enoent) or any
  # other crash degrades to {:error, reason} rather than propagating.
  defp safe_run(runner, args, cwd) do
    runner.(args, cwd)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp default_runner(args, cwd) do
    System.cmd("gh", args, cd: cwd, stderr_to_stdout: true)
  end

  defp normalize_direction!(value) do
    case normalize_direction(value) do
      {:ok, direction} -> direction
      {:error, reason} -> raise ArgumentError, "invalid review direction: #{inspect(reason)}"
    end
  end

  defp empty_direction, do: %{summary: nil, targets: [], verification: []}

  defp empty_direction?(%{summary: summary, targets: targets, verification: verification}),
    do: blank?(summary) and targets == [] and verification == []

  defp normalize_targets(nil), do: {:ok, []}

  defp normalize_targets(targets) when is_list(targets) and length(targets) <= @max_targets do
    normalize_items(targets, &normalize_target/1)
  end

  defp normalize_targets(targets) when is_list(targets),
    do: {:error, {:too_many_review_targets, length(targets), @max_targets}}

  defp normalize_targets(_targets), do: {:error, :review_targets_must_be_a_list}

  defp normalize_target(target) when is_map(target) do
    with {:ok, path} <- required_path(fetch(target, :path)),
         {:ok, line_start} <- required_positive_integer(fetch(target, :line_start), :line_start),
         {:ok, line_end} <- optional_line_end(fetch(target, :line_end), line_start),
         {:ok, question} <- required_text(fetch(target, :question), @max_question_length, :question) do
      {:ok, %{path: path, line_start: line_start, line_end: line_end, question: question}}
    end
  end

  defp normalize_target(_target), do: {:error, :review_target_must_be_an_object}

  defp normalize_verifications(nil), do: {:ok, []}

  defp normalize_verifications(items) when is_list(items) and length(items) <= @max_verifications do
    normalize_items(items, &normalize_verification/1)
  end

  defp normalize_verifications(items) when is_list(items),
    do: {:error, {:too_many_verification_items, length(items), @max_verifications}}

  defp normalize_verifications(_items), do: {:error, :verification_must_be_a_list}

  defp normalize_verification(item) when is_map(item) do
    with {:ok, label} <- required_text(fetch(item, :label), @max_label_length, :label),
         {:ok, expectation} <-
           required_text(fetch(item, :expectation), @max_expectation_length, :expectation),
         {:ok, url} <- optional_url(fetch(item, :url)),
         {:ok, command} <- optional_text(fetch(item, :command), @max_command_length, :command),
         :ok <- exactly_one_reference(url, command) do
      {:ok, %{label: label, expectation: expectation, url: url, command: command}}
    end
  end

  defp normalize_verification(_item), do: {:error, :verification_item_must_be_an_object}

  defp normalize_items(items, normalizer) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case normalizer.(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp render_targets([], _opts), do: nil

  defp render_targets(targets, opts) do
    bullets = Enum.map_join(targets, "\n", &render_target(&1, opts))
    "**Review these**\n#{bullets}"
  end

  defp render_target(target, opts) do
    location = target_location(target)

    reference =
      case exact_target_url(target, opts) do
        nil -> "`#{location}`"
        url -> "[#{location}](#{url})"
      end

    "- #{reference} — #{escape_markdown_text(target.question)}"
  end

  defp render_verification([]), do: nil

  defp render_verification(items) do
    bullets = Enum.map_join(items, "\n", &render_verification_item/1)
    "**Evidence / verification**\n#{bullets}"
  end

  defp render_verification_item(%{url: url} = item) when is_binary(url) do
    "- [#{escape_markdown_text(item.label)}](#{url}) — #{escape_markdown_text(item.expectation)}"
  end

  defp render_verification_item(%{command: command} = item) do
    "- `#{String.replace(command, "`", "")}` — #{escape_markdown_text(item.expectation)}"
  end

  defp target_location(%{path: path, line_start: line_start, line_end: nil}),
    do: "#{path}:#{line_start}"

  defp target_location(%{path: path, line_start: line_start, line_end: line_end}),
    do: "#{path}:#{line_start}-#{line_end}"

  defp exact_target_url(target, opts) do
    repository = Keyword.get(opts, :repository)
    head_oid = Keyword.get(opts, :head_oid)

    if present_string?(repository) and present_string?(head_oid) do
      encoded_path = target.path |> String.split("/") |> Enum.map_join("/", &URI.encode/1)
      line_fragment = "#L#{target.line_start}" <> if(target.line_end, do: "-L#{target.line_end}", else: "")
      "https://github.com/#{repository}/blob/#{head_oid}/#{encoded_path}#{line_fragment}"
    end
  end

  defp insert_after_intro(body, block) do
    trimmed = String.trim_trailing(body)

    case Regex.run(~r/^## (?:What changed|Summary)\s*$/m, trimmed, return: :index) do
      [{heading_start, heading_length}] ->
        search_start = heading_start + heading_length
        remainder = binary_part(trimmed, search_start, byte_size(trimmed) - search_start)

        case Regex.run(~r/^##\s+\S.*$/m, remainder, return: :index) do
          [{next_heading, _length}] ->
            insertion = search_start + next_heading
            before = binary_part(trimmed, 0, insertion) |> String.trim_trailing()
            trailing_body = binary_part(trimmed, insertion, byte_size(trimmed) - insertion) |> String.trim_leading()
            "#{before}\n\n#{block}\n\n#{trailing_body}\n"

          nil ->
            "#{trimmed}\n\n#{block}\n"
        end

      nil ->
        "#{trimmed}\n\n#{block}\n"
    end
  end

  defp required_path(value) do
    with {:ok, path} <- required_text(value, @max_path_length, :path),
         false <- String.starts_with?(path, "/"),
         false <- String.contains?(path, "://"),
         false <- Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".."])) do
      {:ok, path}
    else
      _ -> {:error, :invalid_review_target_path}
    end
  end

  defp required_positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}
  defp required_positive_integer(_value, field), do: {:error, {field, :must_be_a_positive_integer}}

  defp optional_line_end(nil, _line_start), do: {:ok, nil}
  defp optional_line_end(value, line_start) when is_integer(value) and value >= line_start, do: {:ok, value}
  defp optional_line_end(_value, _line_start), do: {:error, {:line_end, :must_follow_line_start}}

  defp required_text(value, max_length, field) do
    case optional_text(value, max_length, field) do
      {:ok, nil} -> {:error, {field, :must_be_non_empty_bounded_text}}
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_text(nil, _max_length, _field), do: {:ok, nil}

  defp optional_text(value, max_length, field) when is_binary(value) do
    text = normalize_inline_text(value)

    cond do
      text == "" -> {:ok, nil}
      String.length(text) > max_length -> {:error, {field, :too_long}}
      true -> {:ok, text}
    end
  end

  defp optional_text(_value, _max_length, field), do: {:error, {field, :must_be_text}}

  defp optional_url(nil), do: {:ok, nil}

  defp optional_url(value) when is_binary(value) do
    value = String.trim(value)
    uri = URI.parse(value)

    if String.length(value) <= @max_url_length and not Regex.match?(~r/[\s)]/, value) and
         uri.scheme in ["http", "https"] and present_string?(uri.host),
       do: {:ok, value},
       else: {:error, {:url, :must_be_an_http_url}}
  end

  defp optional_url(_value), do: {:error, {:url, :must_be_text}}

  defp exactly_one_reference(nil, nil), do: {:error, :verification_requires_url_or_command}

  defp exactly_one_reference(url, command) when is_binary(url) and is_binary(command),
    do: {:error, :verification_requires_one_reference}

  defp exactly_one_reference(_url, _command), do: :ok

  defp bounded_text(value, max_length) when is_binary(value) do
    value
    |> normalize_inline_text()
    |> case do
      "" -> nil
      text -> String.slice(text, 0, max_length)
    end
  end

  defp normalize_inline_text(text), do: text |> String.replace(~r/[\r\n\t]+/, " ") |> String.replace(~r/\s+/, " ") |> String.trim()

  defp escaped_summary(nil), do: nil
  defp escaped_summary(summary), do: escape_markdown_text(summary)

  defp escape_markdown_text(text), do: String.replace(text, ~r/[\\`*_\[\]<>]/, "")

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp blank?(value), do: not present_string?(value)

  defp string_or_empty(value) when is_binary(value), do: value
  defp string_or_empty(_value), do: ""

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp repository_name(%{"nameWithOwner" => value}) when is_binary(value), do: value
  defp repository_name(%{"name" => value}) when is_binary(value), do: value
  defp repository_name(_repository), do: nil

  defp truncate(text) when is_binary(text), do: String.slice(text, 0, 400)
  defp truncate(other), do: inspect(other)
end
