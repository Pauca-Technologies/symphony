defmodule SymphonyElixir.Github.ReviewerRequest do
  @moduledoc """
  Request the Linear-issue owner as PR reviewer on the GitHub PR(s) attached
  to the issue. Driven by `~/.symphony/config.yml`'s `linear_to_github`
  mapping (keyed by Linear `email`, since Linear's User type does not expose
  a GitHub handle anywhere). Owner pick is `assignee_email` → `creator_email`.

  Called from `SymphonyElixir.Orchestrator.reconcile_issue_state/4` when an
  issue transitions into a review state. Never raises: any failure
  (unmapped user, no PR attached, gh exit non-zero) is logged and swallowed,
  because a missed reviewer-add must not break the polling loop.

  The GitHub side is idempotent: re-POSTing a reviewer that is already
  requested is a no-op server-side, so we do not persist "we already did
  this" — the orchestrator can safely call this on every poll while the
  issue sits in a review state.
  """

  require Logger

  alias SymphonyElixir.Linear.Issue

  @pr_url_regex ~r{^https?://github\.com/([^/]+)/([^/]+)/pull/(\d+)}

  @type mapping_entry :: %{linear_email: String.t(), github_login: String.t()} | struct()
  @type runner :: (String.t(), [String.t()] -> {Collectable.t(), non_neg_integer()})

  @spec request_for_issue(Issue.t(), [mapping_entry()]) :: :ok
  def request_for_issue(issue, mapping), do: request_for_issue(issue, mapping, [])

  @spec request_for_issue(Issue.t(), [mapping_entry()], keyword()) :: :ok
  def request_for_issue(%Issue{} = issue, mapping, opts) when is_list(mapping) and is_list(opts) do
    runner = Keyword.get(opts, :runner, &default_runner/2)

    with {:ok, email} <- pick_owner_email(issue),
         {:ok, login} <- lookup_login(email, mapping),
         {:ok, prs} <- extract_prs(issue) do
      Enum.each(prs, fn pr -> request_one(pr, login, runner, issue) end)
      :ok
    else
      {:skip, reason} ->
        Logger.debug(
          "ReviewerRequest skipped: reason=#{inspect(reason)} issue=#{issue_context(issue)}"
        )

        :ok
    end
  end

  def request_for_issue(_issue, _mapping, _opts), do: :ok

  defp pick_owner_email(%Issue{assignee_email: email}) when is_binary(email) and email != "",
    do: {:ok, email}

  defp pick_owner_email(%Issue{creator_email: email}) when is_binary(email) and email != "",
    do: {:ok, email}

  defp pick_owner_email(_), do: {:skip, :no_owner_email}

  defp lookup_login(email, mapping) do
    case Enum.find(mapping, &mapping_matches?(&1, email)) do
      nil ->
        {:skip, {:unmapped_linear_email, email}}

      entry ->
        case mapping_login(entry) do
          login when is_binary(login) and login != "" -> {:ok, login}
          _ -> {:skip, {:malformed_mapping_entry, entry}}
        end
    end
  end

  defp mapping_matches?(entry, email) when is_map(entry) do
    case mapping_email(entry) do
      candidate when is_binary(candidate) -> String.downcase(candidate) == String.downcase(email)
      _ -> false
    end
  end

  defp mapping_matches?(_entry, _email), do: false

  defp mapping_email(%{linear_email: email}), do: email
  defp mapping_email(%{"linear_email" => email}), do: email
  defp mapping_email(_), do: nil

  defp mapping_login(%{github_login: login}), do: login
  defp mapping_login(%{"github_login" => login}), do: login
  defp mapping_login(_), do: nil

  defp extract_prs(%Issue{attachment_urls: urls}) when is_list(urls) do
    prs =
      urls
      |> Enum.flat_map(&parse_pr_url/1)
      |> Enum.uniq()

    case prs do
      [] -> {:skip, :no_pr_attached}
      prs -> {:ok, prs}
    end
  end

  defp extract_prs(_), do: {:skip, :no_pr_attached}

  defp parse_pr_url(url) when is_binary(url) do
    case Regex.run(@pr_url_regex, url) do
      [_, owner, repo, pr] -> [{owner, repo, String.to_integer(pr)}]
      _ -> []
    end
  end

  defp parse_pr_url(_), do: []

  defp request_one({owner, repo, pr_number}, login, runner, issue) do
    args = [
      "api",
      "-X",
      "POST",
      "repos/#{owner}/#{repo}/pulls/#{pr_number}/requested_reviewers",
      "-f",
      "reviewers[]=#{login}"
    ]

    case runner.("gh", args) do
      {_output, 0} ->
        Logger.info(
          "ReviewerRequest requested reviewer=#{login} pr=#{owner}/#{repo}##{pr_number} " <>
            "issue=#{issue_context(issue)}"
        )

      {output, code} ->
        # GitHub returns 422 for an already-requested reviewer; that's the
        # idempotent no-op path. We can't distinguish without parsing the
        # response, so warn-and-swallow on any non-zero and rely on the
        # orchestrator continuing to call us each poll.
        Logger.warning(
          "ReviewerRequest gh exit=#{code} reviewer=#{login} pr=#{owner}/#{repo}##{pr_number} " <>
            "issue=#{issue_context(issue)} output=#{truncate(output)}"
        )
    end
  end

  defp default_runner(cmd, args) do
    System.cmd(cmd, args, stderr_to_stdout: true)
  end

  defp issue_context(%Issue{id: id, identifier: identifier}) do
    "id=#{inspect(id)} identifier=#{inspect(identifier)}"
  end

  defp truncate(text) when is_binary(text), do: String.slice(text, 0, 400)
  defp truncate(other), do: inspect(other)
end
