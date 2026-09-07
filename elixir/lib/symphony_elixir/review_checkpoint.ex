defmodule SymphonyElixir.ReviewCheckpoint do
  @moduledoc "Conservative identities for resuming delivery of a validated review."

  alias SymphonyElixir.{Config, Github.PrReviewSection, ReviewGate, RunManifest}

  @max_bytes 262_144
  @max_age_seconds 86_400
  @snapshot_query """
  query SymphonyReviewDelivery($id: ID!) {
    node(id: $id) { ... on PullRequest {
      state headRefOid baseRefOid body reviewDecision
      comments(first: 100) { nodes { id body updatedAt } pageInfo { hasNextPage } }
      reviews(first: 100) { nodes { id body state submittedAt } pageInfo { hasNextPage } }
      reviewThreads(first: 100) { nodes {
        id isResolved isOutdated
        comments(first: 100) { nodes { id body updatedAt } pageInfo { hasNextPage } }
      } pageInfo { hasNextPage } }
    } }
  }
  """

  @doc "Capture all inputs needed to reuse an approval; unavailable evidence disables reuse."
  @spec identity(map()) :: {:ok, map()} | {:error, term()}
  def identity(context) do
    packet = context.packet_result.packet

    with true <- is_function(Keyword.get(context.opts, :review_checkpoint_writer), 1),
         true <- is_nil(context.worker_host),
         true <- valid_sha?(context.reviewed_sha),
         true <- valid_sha?(get_in(packet, [:candidate, :base_sha])),
         false <- get_in(packet, [:issue, :scope_amendments_truncated]) == true,
         {"", 0} <- System.cmd("git", ["status", "--porcelain", "--untracked-files=all"], cd: context.workspace),
         {local_head, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: context.workspace),
         true <- String.trim(local_head) == context.reviewed_sha,
         {:ok, snapshot} <- snapshot(context),
         {:ok, rules} <- rule_digests(context.workspace, Map.get(packet, :repository_rules, [])) do
      {:ok,
       %{
         "packet" => RunManifest.config_digest(packet),
         "policy" => RunManifest.config_digest(%{workflow: context.review_workflow, settings: context.settings, runtime: Config.settings!(), harness: Base.encode16(ReviewGate.module_info(:md5))}),
         "feedback" => RunManifest.config_digest(snapshot),
         "rules" => RunManifest.config_digest(rules)
       }}
    else
      _ -> {:error, :evidence_unavailable}
    end
  rescue
    _ -> {:error, :evidence_unavailable}
  end

  @doc "Match a bounded, unexpired checkpoint against the current review inputs."
  @spec lookup(map() | nil, map()) :: {:ok, map()} | {:error, term()}
  def lookup(%{"identity" => saved, "verdict" => verdict, "capturedAt" => captured} = checkpoint, current)
      when is_map(saved) and is_map(verdict) and is_integer(captured) do
    age = System.system_time(:second) - captured

    cond do
      byte_size(Jason.encode!(checkpoint)) > @max_bytes -> {:error, :checkpoint_too_large}
      age < 0 or age > @max_age_seconds -> {:error, :checkpoint_expired}
      saved != current -> {:error, {:changed_inputs, Enum.filter(Map.keys(current), &(saved[&1] != current[&1]))}}
      verdict["verdict"] != "approve" -> {:error, :not_approved}
      true -> {:ok, verdict}
    end
  end

  def lookup(_checkpoint, _current), do: {:error, :checkpoint_missing}

  @doc "Package a validated approval for trusted control-state persistence."
  @spec build(map(), map()) :: {:ok, map()} | {:error, term()}
  def build(identity, %{"verdict" => "approve"} = verdict) do
    checkpoint = %{"identity" => identity, "verdict" => verdict, "capturedAt" => System.system_time(:second)}
    if byte_size(Jason.encode!(checkpoint)) <= @max_bytes, do: {:ok, checkpoint}, else: {:error, :checkpoint_too_large}
  end

  def build(_identity, _verdict), do: {:error, :not_approved}

  defp snapshot(%{pr: %{id: id} = pr} = context) when is_binary(id) do
    runner = Keyword.get(context.opts, :pr_runner, &default_runner/2)
    args = ["api", "graphql", "-f", "query=" <> @snapshot_query, "-f", "id=" <> id]

    with {output, 0} <- runner.(args, context.workspace),
         true <- byte_size(output) <= 1_048_576,
         {:ok, %{"data" => %{"node" => snapshot}} = response} <- Jason.decode(output),
         false <- Map.has_key?(response, "errors"),
         %{"state" => "OPEN", "headRefOid" => head, "baseRefOid" => base, "body" => body} <- snapshot,
         true <- head == context.reviewed_sha and base == pr.base_oid,
         true <- complete_connection?(snapshot["comments"]),
         true <- complete_connection?(snapshot["reviews"]),
         true <- complete_connection?(snapshot["reviewThreads"]),
         true <- Enum.all?(snapshot["reviewThreads"]["nodes"], &complete_connection?(&1["comments"])) do
      body =
        case PrReviewSection.remove_from_body(body) do
          :unchanged -> body
          {:changed, clean} -> clean
        end

      {:ok, Map.put(snapshot, "body", String.trim(body))}
    else
      _ -> {:error, :feedback_unavailable}
    end
  end

  defp snapshot(_context), do: {:error, :no_pr}

  defp complete_connection?(%{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}), do: is_list(nodes)
  defp complete_connection?(_value), do: false

  defp rule_digests(workspace, rules) do
    Enum.reduce_while(rules, {:ok, %{}}, fn rule, {:ok, acc} ->
      case File.read(Path.join(workspace, rule.path)) do
        {:ok, contents} -> {:cont, {:ok, Map.put(acc, rule.path, RunManifest.config_digest(%{contents: contents}))}}
        error -> {:halt, error}
      end
    end)
  end

  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, sha)
  defp default_runner(args, cwd), do: System.cmd("gh", args, cd: cwd, stderr_to_stdout: true)
end
