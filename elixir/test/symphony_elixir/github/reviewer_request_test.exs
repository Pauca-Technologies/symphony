defmodule SymphonyElixir.Github.ReviewerRequestTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Github.ReviewerRequest
  alias SymphonyElixir.Linear.Issue

  describe "request_for_issue/3" do
    test "shells out to gh requested_reviewers when owner email maps to a github login" do
      runner_calls = capture_runner_calls()

      issue = %Issue{
        id: "issue-1",
        identifier: "UDPE-1",
        assignee_email: "raul@pauca.co",
        attachment_urls: ["https://github.com/Pauca-Technologies/udp-dashboard-v2/pull/1304"]
      }

      mapping = [%{linear_email: "raul@pauca.co", github_login: "raulmt"}]

      assert :ok = ReviewerRequest.request_for_issue(issue, mapping, runner: runner_fn(runner_calls))

      assert [
               {"gh",
                [
                  "api",
                  "-X",
                  "POST",
                  "repos/Pauca-Technologies/udp-dashboard-v2/pulls/1304/requested_reviewers",
                  "-f",
                  "reviewers[]=raulmt"
                ]}
             ] = recorded_calls(runner_calls)
    end

    test "falls back to creator_email when assignee_email is empty" do
      runner_calls = capture_runner_calls()

      issue = %Issue{
        id: "issue-2",
        identifier: "UDPE-2",
        assignee_email: nil,
        creator_email: "jonathan@pauca.co",
        attachment_urls: ["https://github.com/Pauca-Technologies/udp-dashboard-v2/pull/9"]
      }

      mapping = [%{linear_email: "jonathan@pauca.co", github_login: "jghell"}]

      assert :ok = ReviewerRequest.request_for_issue(issue, mapping, runner: runner_fn(runner_calls))

      assert [{"gh", args}] = recorded_calls(runner_calls)
      assert "reviewers[]=jghell" in args
    end

    test "compares mapping emails case-insensitively" do
      runner_calls = capture_runner_calls()

      issue = %Issue{
        id: "issue-3",
        identifier: "UDPE-3",
        assignee_email: "Raul@PAUCA.co",
        attachment_urls: ["https://github.com/o/r/pull/1"]
      }

      mapping = [%{linear_email: "raul@pauca.co", github_login: "raulmt"}]

      assert :ok = ReviewerRequest.request_for_issue(issue, mapping, runner: runner_fn(runner_calls))

      assert [{"gh", _}] = recorded_calls(runner_calls)
    end

    test "accepts string-keyed mapping entries (yaml-loaded shape) as well as atom-keyed" do
      runner_calls = capture_runner_calls()

      issue = %Issue{
        id: "issue-4",
        identifier: "UDPE-4",
        assignee_email: "nicolas@pauca.co",
        attachment_urls: ["https://github.com/o/r/pull/42"]
      }

      mapping = [%{"linear_email" => "nicolas@pauca.co", "github_login" => "nico"}]

      assert :ok = ReviewerRequest.request_for_issue(issue, mapping, runner: runner_fn(runner_calls))

      assert [{"gh", args}] = recorded_calls(runner_calls)
      assert "reviewers[]=nico" in args
    end

    test "extracts every github PR URL from attachment_urls and skips non-PR links" do
      runner_calls = capture_runner_calls()

      issue = %Issue{
        id: "issue-5",
        identifier: "UDPE-5",
        assignee_email: "raul@pauca.co",
        attachment_urls: [
          "https://example.org/some-doc",
          "https://github.com/o/r/pull/100",
          "https://github.com/o/r/issues/200",
          "https://github.com/o/r2/pull/300"
        ]
      }

      mapping = [%{linear_email: "raul@pauca.co", github_login: "raulmt"}]

      assert :ok = ReviewerRequest.request_for_issue(issue, mapping, runner: runner_fn(runner_calls))

      calls = recorded_calls(runner_calls)
      assert length(calls) == 2

      pr_paths =
        calls
        |> Enum.map(fn {"gh", args} ->
          Enum.find(args, &String.contains?(&1, "/pulls/"))
        end)
        |> Enum.sort()

      assert pr_paths == [
               "repos/o/r/pulls/100/requested_reviewers",
               "repos/o/r2/pulls/300/requested_reviewers"
             ]
    end

    test "no-op when owner email is missing on both assignee and creator" do
      runner_calls = capture_runner_calls()

      issue = %Issue{
        id: "issue-6",
        identifier: "UDPE-6",
        assignee_email: nil,
        creator_email: nil,
        attachment_urls: ["https://github.com/o/r/pull/1"]
      }

      assert :ok = ReviewerRequest.request_for_issue(issue, [], runner: runner_fn(runner_calls))
      assert recorded_calls(runner_calls) == []
    end

    test "no-op when owner email is not in mapping" do
      runner_calls = capture_runner_calls()

      issue = %Issue{
        id: "issue-7",
        identifier: "UDPE-7",
        assignee_email: "someone@external.com",
        attachment_urls: ["https://github.com/o/r/pull/1"]
      }

      mapping = [%{linear_email: "raul@pauca.co", github_login: "raulmt"}]

      assert :ok = ReviewerRequest.request_for_issue(issue, mapping, runner: runner_fn(runner_calls))
      assert recorded_calls(runner_calls) == []
    end

    test "no-op when no PR url is attached" do
      runner_calls = capture_runner_calls()

      issue = %Issue{
        id: "issue-8",
        identifier: "UDPE-8",
        assignee_email: "raul@pauca.co",
        attachment_urls: ["https://example.org/some-doc"]
      }

      mapping = [%{linear_email: "raul@pauca.co", github_login: "raulmt"}]

      assert :ok = ReviewerRequest.request_for_issue(issue, mapping, runner: runner_fn(runner_calls))
      assert recorded_calls(runner_calls) == []
    end

    test "swallows non-zero gh exit so a single bad PR does not blow up the orchestrator" do
      issue = %Issue{
        id: "issue-9",
        identifier: "UDPE-9",
        assignee_email: "raul@pauca.co",
        attachment_urls: ["https://github.com/o/r/pull/1"]
      }

      mapping = [%{linear_email: "raul@pauca.co", github_login: "raulmt"}]

      failing_runner = fn _cmd, _args -> {"some 422 body", 1} end

      assert :ok = ReviewerRequest.request_for_issue(issue, mapping, runner: failing_runner)
    end

    test "the 2-arity helper is a no-op when there is no owner email" do
      issue = %Issue{id: "i", identifier: "UDPE-0", assignee_email: nil, creator_email: nil, attachment_urls: []}
      assert :ok = ReviewerRequest.request_for_issue(issue, [])
    end

    test "no-op for a non-Issue argument" do
      assert :ok = ReviewerRequest.request_for_issue(:not_an_issue, [], [])
    end

    test "skips when the matched mapping entry has no github login" do
      runner_calls = capture_runner_calls()

      issue = %Issue{
        id: "i",
        identifier: "UDPE-10",
        assignee_email: "raul@pauca.co",
        attachment_urls: ["https://github.com/o/r/pull/1"]
      }

      mapping = [%{linear_email: "raul@pauca.co"}]

      assert :ok = ReviewerRequest.request_for_issue(issue, mapping, runner: runner_fn(runner_calls))
      assert recorded_calls(runner_calls) == []
    end

    test "ignores malformed mapping entries (non-map, non-binary email, missing email)" do
      runner_calls = capture_runner_calls()

      issue = %Issue{
        id: "i",
        identifier: "UDPE-11",
        assignee_email: "raul@pauca.co",
        attachment_urls: ["https://github.com/o/r/pull/1"]
      }

      mapping = [:not_a_map, %{linear_email: 123}, %{github_login: "x"}]

      assert :ok = ReviewerRequest.request_for_issue(issue, mapping, runner: runner_fn(runner_calls))
      assert recorded_calls(runner_calls) == []
    end

    test "skips when owner maps but attachment_urls is not a list" do
      runner_calls = capture_runner_calls()

      issue = %Issue{
        id: "i",
        identifier: "UDPE-12",
        assignee_email: "raul@pauca.co",
        attachment_urls: nil
      }

      mapping = [%{linear_email: "raul@pauca.co", github_login: "raulmt"}]

      assert :ok = ReviewerRequest.request_for_issue(issue, mapping, runner: runner_fn(runner_calls))
      assert recorded_calls(runner_calls) == []
    end

    test "ignores non-binary entries in attachment_urls" do
      runner_calls = capture_runner_calls()

      issue = %Issue{
        id: "i",
        identifier: "UDPE-13",
        assignee_email: "raul@pauca.co",
        attachment_urls: [123, "https://github.com/o/r/pull/5"]
      }

      mapping = [%{linear_email: "raul@pauca.co", github_login: "raulmt"}]

      assert :ok = ReviewerRequest.request_for_issue(issue, mapping, runner: runner_fn(runner_calls))
      assert [{"gh", _args}] = recorded_calls(runner_calls)
    end

    test "the default runner shells out to gh found on PATH" do
      shim_dir = Path.join(System.tmp_dir!(), "gh-shim-#{System.unique_integer([:positive])}")
      File.mkdir_p!(shim_dir)
      gh = Path.join(shim_dir, "gh")
      File.write!(gh, "#!/bin/sh\nexit 0\n")
      File.chmod!(gh, 0o755)

      original_path = System.get_env("PATH")

      on_exit(fn ->
        restore_path(original_path)
        File.rm_rf(shim_dir)
      end)

      System.put_env("PATH", shim_dir <> ":" <> (original_path || ""))

      issue = %Issue{
        id: "i",
        identifier: "UDPE-14",
        assignee_email: "raul@pauca.co",
        attachment_urls: ["https://github.com/o/r/pull/1"]
      }

      mapping = [%{linear_email: "raul@pauca.co", github_login: "raulmt"}]

      # No :runner opt -> exercises the default System.cmd-based runner.
      assert :ok = ReviewerRequest.request_for_issue(issue, mapping)
    end

    test "swallows and truncates non-binary gh output" do
      issue = %Issue{
        id: "i",
        identifier: "UDPE-15",
        assignee_email: "raul@pauca.co",
        attachment_urls: ["https://github.com/o/r/pull/1"]
      }

      mapping = [%{linear_email: "raul@pauca.co", github_login: "raulmt"}]
      failing_runner = fn _cmd, _args -> {~c"charlist output", 1} end

      assert :ok = ReviewerRequest.request_for_issue(issue, mapping, runner: failing_runner)
    end
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(value), do: System.put_env("PATH", value)

  defp capture_runner_calls do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    agent
  end

  defp runner_fn(agent) do
    fn cmd, args ->
      Agent.update(agent, fn calls -> calls ++ [{cmd, args}] end)
      {"", 0}
    end
  end

  defp recorded_calls(agent), do: Agent.get(agent, & &1)
end
