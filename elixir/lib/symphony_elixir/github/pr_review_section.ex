defmodule SymphonyElixir.Github.PrReviewSection do
  @moduledoc """
  Owns the deterministic "How to review this PR" section that the reviewer
  agent's verdict drives onto the GitHub PR body.

  The reviewer agent is Linear-read-only and never edits the PR itself; instead
  it emits a `review_effort` tier (`:none | :skim | :focused | :thorough` — how
  hard a human should review the change) and free-form `human_review` markdown
  in its verdict JSON. `ReviewGate` hands those to this module, which renders a
  marker-delimited section and upserts it into the PR body via GitHub's
  `updatePullRequest` GraphQL mutation.

  Determinism lives here, not in the LLM:

    * the section markers (`<!-- symphony:review:start/end -->`) and heading are
      fixed, so the region is overwritten in place every run instead of
      appended/duplicated;
    * the 🟢/🔵/🟠/🔴 review-effort badge is rendered from the enum, not the model;
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
  @default_heading "## 🤖 How to review this PR"
  @pr_ref_keys [:pr_ref, :pr_url]

  @badges %{
    none: "🟢 **None** — safe to merge, no human review needed",
    skim: "🔵 **Skim** — a light skim is enough",
    focused: "🟠 **Focused** — review the called-out areas closely",
    thorough: "🔴 **Thorough** — deep, focused review; highest risk"
  }

  @type effort :: :none | :skim | :focused | :thorough
  @type pr :: %{
          required(:number) => pos_integer(),
          required(:body) => String.t(),
          optional(:id) => String.t() | nil,
          optional(:head_oid) => String.t() | nil
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
        explicit_pr_ref_args(opts) ++ ["--json", "id,number,body,headRefOid"]

    case safe_run(runner, args, workspace) do
      {output, 0} -> parse_pr(output)
      {:error, reason} -> {:skip, reason}
      {_output, _code} -> {:skip, :no_pr}
    end
  end

  @doc """
  Upsert the review section onto `pr`'s body in `workspace`.

  Returns `:written` (the PR body was edited), `:unchanged` (the section already
  matched, no write), or `:skipped` (no PR, or the `gh` update failed).
  Never raises.
  """
  @spec upsert(Path.t(), pr() | nil, effort(), String.t(), keyword()) :: :written | :unchanged | :skipped
  def upsert(workspace, %{number: number, body: body} = pr, effort, human_review, opts)
      when is_binary(workspace) and is_integer(number) do
    block = render(effort, human_review, opts)

    case apply_to_body(body, block) do
      :unchanged -> :unchanged
      {:changed, new_body} -> write_body(workspace, pr, new_body, opts)
    end
  end

  def upsert(_workspace, _pr, _risk, _human_review, _opts), do: :skipped

  @doc """
  Render the marker-delimited section block: markers + heading + badge +
  the reviewer's prose. Pure; the reviewer supplies only the prose.
  """
  @spec render(effort(), String.t(), keyword()) :: String.t()
  def render(effort, human_review, opts \\ []) do
    heading = Keyword.get(opts, :section_heading) || @default_heading
    badge = Map.get(@badges, effort, @badges.focused)
    prose = prose_or_fallback(human_review)

    """
    #{@marker_start}
    #{heading}

    #{badge}

    #{prose}
    #{@marker_end}
    """
    |> String.trim_trailing()
  end

  @doc """
  Replace the existing marker region with `block`, or append it when absent.
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
        {:changed, String.trim_trailing(body) <> "\n\n" <> block <> "\n"}
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
           head_oid: string_or_nil(Map.get(decoded, "headRefOid"))
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

  defp prose_or_fallback(human_review) do
    case String.trim(to_string(human_review)) do
      "" -> "_The reviewer did not provide written guidance._"
      trimmed -> trimmed
    end
  end

  defp string_or_empty(value) when is_binary(value), do: value
  defp string_or_empty(_value), do: ""

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp truncate(text) when is_binary(text), do: String.slice(text, 0, 400)
  defp truncate(other), do: inspect(other)
end
