defmodule SymphonyElixir.Github.PrReviewSection do
  @moduledoc """
  Owns the deterministic "How to review this PR" section that the reviewer
  agent's verdict drives onto the GitHub PR body.

  The reviewer agent is Linear-read-only and never edits the PR itself; instead
  it emits a `risk` tier (`:safe | :skim | :medium | :high`) and free-form
  `human_review` markdown in its verdict JSON. `ReviewGate` hands those to this
  module, which renders a marker-delimited section and upserts it into the PR
  body via `gh pr edit`.

  Determinism lives here, not in the LLM:

    * the section markers (`<!-- symphony:review:start/end -->`) and heading are
      fixed, so the region is overwritten in place every run instead of
      appended/duplicated;
    * the 🟢/🔵/🟠/🔴 risk badge is rendered from the enum, not the model;
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

  @badges %{
    safe: "🟢 **Safe** — no human review required",
    skim: "🔵 **Skim** — broadly safe; a few highlights need a closer look",
    medium: "🟠 **Medium risk** — review the risky changes below",
    high: "🔴 **High risk** — focused review required; risks listed below"
  }

  @type risk :: :safe | :skim | :medium | :high
  @type pr :: %{number: pos_integer(), body: String.t()}
  # (gh args, cwd) -> {output, exit_status}; mirrors Github.ReviewerRequest.
  @type runner :: ([String.t()], Path.t() -> {String.t(), non_neg_integer()})

  @doc """
  Resolve the PR for the current branch in `workspace` via `gh pr view`.

  Returns `{:ok, %{number:, body:}}` or `{:skip, reason}` (no PR, unparseable
  output, or `gh` unavailable). Never raises.
  """
  @spec resolve_pr(Path.t(), keyword()) :: {:ok, pr()} | {:skip, term()}
  def resolve_pr(workspace, opts \\ []) when is_binary(workspace) do
    runner = Keyword.get(opts, :pr_runner, &default_runner/2)

    case safe_run(runner, ["pr", "view", "--json", "number,body"], workspace) do
      {output, 0} -> parse_pr(output)
      {:error, reason} -> {:skip, reason}
      {_output, _code} -> {:skip, :no_pr}
    end
  end

  @doc """
  Upsert the review section onto `pr`'s body in `workspace`.

  Returns `:written` (the PR body was edited), `:unchanged` (the section already
  matched, no write), or `:skipped` (no PR, or the `gh` edit failed). Never
  raises.
  """
  @spec upsert(Path.t(), pr() | nil, risk(), String.t(), keyword()) :: :written | :unchanged | :skipped
  def upsert(workspace, %{number: number, body: body}, risk, human_review, opts)
      when is_binary(workspace) and is_integer(number) do
    block = render(risk, human_review, opts)

    case apply_to_body(body, block) do
      :unchanged -> :unchanged
      {:changed, new_body} -> write_body(workspace, number, new_body, opts)
    end
  end

  def upsert(_workspace, _pr, _risk, _human_review, _opts), do: :skipped

  @doc """
  Render the marker-delimited section block: markers + heading + badge +
  the reviewer's prose. Pure; the reviewer supplies only the prose.
  """
  @spec render(risk(), String.t(), keyword()) :: String.t()
  def render(risk, human_review, opts \\ []) do
    heading = Keyword.get(opts, :section_heading) || @default_heading
    badge = Map.get(@badges, risk, @badges.medium)
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

  defp parse_pr(output) do
    case Jason.decode(output) do
      {:ok, %{"number" => number} = decoded} when is_integer(number) ->
        {:ok, %{number: number, body: string_or_empty(Map.get(decoded, "body"))}}

      _ ->
        {:skip, :pr_view_unparseable}
    end
  end

  defp write_body(workspace, number, new_body, opts) do
    runner = Keyword.get(opts, :pr_runner, &default_runner/2)
    tmp = Path.join(System.tmp_dir!(), "symphony-pr-body-#{System.unique_integer([:positive])}.md")
    File.write!(tmp, new_body)

    try do
      case safe_run(runner, ["pr", "edit", Integer.to_string(number), "--body-file", tmp], workspace) do
        {_output, 0} ->
          :written

        {:error, reason} ->
          Logger.warning("PrReviewSection gh edit failed pr=##{number} reason=#{inspect(reason)}")
          :skipped

        {output, code} ->
          Logger.warning("PrReviewSection gh edit exit=#{code} pr=##{number} output=#{truncate(output)}")
          :skipped
      end
    after
      _ = File.rm(tmp)
    end
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

  defp truncate(text) when is_binary(text), do: String.slice(text, 0, 400)
  defp truncate(other), do: inspect(other)
end
