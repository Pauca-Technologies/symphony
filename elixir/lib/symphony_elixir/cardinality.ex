defmodule SymphonyElixir.Cardinality do
  @moduledoc """
  Cardinality gate for the multi-repo Symphony driver.

  Per the audit (§9.4) and implementation plan T23/T24, every dispatchable
  Linear issue must satisfy:

    1. Has at most one `repo:<name>` label. (Two PRs would target two repos.)
    2. If it has children (Linear native sub-issues), it is a parent and
       MUST NOT carry a `repo:<name>` label and MUST NOT have an attached
       PR. Parents are cross-repo coordination; per-repo work is the
       children.
    3. Has at most one attached PR. (Detected via attachment URLs that
       look like GitHub PR URLs.)

  Two-PR resolution (deferred to handoff time): if a Symphony-opened PR
  on this issue coexists with a human-opened PR, the agent closes
  Symphony's PR with the `[symphony:superseded — human-opened PR #<N>
  takes precedence]` marker and skips. The detection helper lives here;
  the close-and-skip happens in `Codex.DynamicTool` when the agent
  attempts to push a PR.

  All checks use bulk-poll fields populated by `Linear.Client` so the
  gate adds zero extra API calls per issue.

  Cutover: when `cardinality_enforced_from` is set in repos.yaml,
  issues with `createdAt` strictly before that date are skipped
  silently (returned as `:ok`). Issues created on or after the cutover
  date are gated normally.
  """

  alias SymphonyElixir.{Linear.Issue, RepoConfig}

  @type violation ::
          :multiple_repo_labels
          | :parent_with_repo_label
          | :parent_with_pr
          | :multiple_prs

  @type check_result :: :ok | {:violations, [violation()]} | {:not_enforced, atom()}

  @github_pr_pattern ~r{https?://github\.com/[^/]+/[^/]+/pull/\d+}

  @doc """
  Run the cardinality gate against a single issue. Returns `:ok` if the
  issue passes, `{:violations, [...]}` if it fails. When the issue was
  created before the configured cutover date, returns
  `{:not_enforced, :pre_cutover}`.
  """
  @spec check(Issue.t(), RepoConfig.t()) :: check_result()
  def check(%Issue{} = issue, %{defaults: %{cardinality_enforced_from: cutover}} = _config) do
    if pre_cutover?(issue, cutover) do
      {:not_enforced, :pre_cutover}
    else
      do_check(issue)
    end
  end

  def check(%Issue{} = issue, _config), do: do_check(issue)

  defp do_check(%Issue{} = issue) do
    violations =
      []
      |> maybe_add(repo_label_violation(issue))
      |> maybe_add(parent_label_violation(issue))
      |> maybe_add(parent_pr_violation(issue))
      |> maybe_add(multi_pr_violation(issue))

    case violations do
      [] -> :ok
      v -> {:violations, Enum.reverse(v)}
    end
  end

  @doc """
  Format a human-readable comment body explaining the violations.
  Always emitted with the cross-condition idempotency marker so the
  Linear adapter can suppress duplicates.
  """
  @spec violation_comment(Issue.t(), [violation()]) :: String.t()
  def violation_comment(%Issue{} = issue, violations) when is_list(violations) do
    bullets = Enum.map_join(violations, "\n", &explain_violation(&1, issue))

    """
    <!-- symphony:routing-warned -->
    Symphony cannot dispatch this issue: cardinality contract violated.

    #{bullets}

    See the harness audit (§9.4) for the contract: 1 PR per issue max,
    1 repo per issue, parents have no PR/no repo. Cross-repo work
    requires a parent issue plus per-repo child issues.
    """
  end

  @doc """
  Detect whether the issue has multiple PRs attached. Used by the
  agent runner's handoff path for the two-PR resolution case.
  """
  @spec pr_urls(Issue.t()) :: [String.t()]
  def pr_urls(%Issue{attachment_urls: urls}) when is_list(urls) do
    Enum.filter(urls, &github_pr_url?/1)
  end

  def pr_urls(_issue), do: []

  defp pre_cutover?(_issue, nil), do: false

  defp pre_cutover?(%Issue{created_at: %DateTime{} = created_at}, %Date{} = cutover) do
    Date.compare(DateTime.to_date(created_at), cutover) == :lt
  end

  defp pre_cutover?(_issue, _cutover), do: false

  defp repo_label_violation(%Issue{labels: labels}) when is_list(labels) do
    case Enum.count(labels, &repo_label?/1) do
      n when n > 1 -> :multiple_repo_labels
      _ -> nil
    end
  end

  defp repo_label_violation(_issue), do: nil

  defp parent_label_violation(%Issue{children: children, labels: labels})
       when is_list(children) and length(children) > 0 do
    if Enum.any?(labels, &repo_label?/1), do: :parent_with_repo_label, else: nil
  end

  defp parent_label_violation(_issue), do: nil

  defp parent_pr_violation(%Issue{children: children} = issue)
       when is_list(children) and length(children) > 0 do
    if pr_urls(issue) != [], do: :parent_with_pr, else: nil
  end

  defp parent_pr_violation(_issue), do: nil

  defp multi_pr_violation(%Issue{} = issue) do
    case pr_urls(issue) do
      [_, _ | _] -> :multiple_prs
      _ -> nil
    end
  end

  defp maybe_add(list, nil), do: list
  defp maybe_add(list, item), do: [item | list]

  defp repo_label?(label) when is_binary(label) do
    String.starts_with?(String.downcase(String.trim(label)), "repo:")
  end

  defp repo_label?(_), do: false

  defp github_pr_url?(url) when is_binary(url), do: Regex.match?(@github_pr_pattern, url)
  defp github_pr_url?(_), do: false

  defp explain_violation(:multiple_repo_labels, %Issue{labels: labels}) do
    repo_labels = labels |> Enum.filter(&repo_label?/1) |> Enum.join(", ")
    "- Multiple `repo:<name>` labels detected (#{repo_labels}). Keep exactly one."
  end

  defp explain_violation(:parent_with_repo_label, _issue) do
    "- This issue has sub-issues (Linear parent) but also carries a `repo:<name>` label. Parents must not be routed; move per-repo work to children."
  end

  defp explain_violation(:parent_with_pr, _issue) do
    "- This issue has sub-issues (Linear parent) but also has an attached PR. Parents must not have PRs; attach the PR to the child issue instead."
  end

  defp explain_violation(:multiple_prs, %Issue{} = issue) do
    urls = pr_urls(issue) |> Enum.map_join(", ", &"`#{&1}`")
    "- Multiple PRs attached (#{urls}). Each issue may have at most one PR."
  end

  defp explain_violation(other, _issue), do: "- Unknown violation: #{inspect(other)}"
end
