defmodule SymphonyElixir.TestWorkerBudget do
  @moduledoc """
  Host-owned per-agent budget for test-runner worker processes.

  The budget is deliberately separate from Symphony's agent concurrency. It is
  exported as a runner-neutral environment variable and included in the first
  turn so agents can pass each runner's supported CLI/config option.
  """

  alias SymphonyElixir.{Config, PromptSection}

  @env_name "SYMPHONY_TEST_WORKER_LIMIT"

  @spec limit() :: pos_integer()
  def limit, do: Config.settings!().agent.test_worker_limit

  @spec port_env() :: [{charlist(), charlist()}]
  def port_env do
    [{String.to_charlist(@env_name), limit() |> Integer.to_string() |> String.to_charlist()}]
  end

  @spec shell_export() :: String.t()
  def shell_export, do: "export #{@env_name}=#{limit()}"

  @spec prompt_section() :: PromptSection.t()
  def prompt_section do
    limit = limit()

    content = """
    ## Host test-worker budget

    Keep test execution within #{limit} concurrent worker processes for this agent. This limit does not reduce Symphony's agent concurrency.

    `#{@env_name}=#{limit}` is present in the agent environment. Pass the runner's supported option explicitly, for example:

    - Vitest: `vitest --maxWorkers=#{limit}`
    - Playwright: `playwright test --workers=#{limit}`

    Repository test configuration may read `process.env.#{@env_name}`. Do not raise or bypass this limit; split validation into sequential commands when necessary.
    """

    PromptSection.new(
      id: "symphony.test_worker_budget",
      type: :runtime_constraint,
      source: "symphony:host_config",
      version: "test-worker-budget/v1",
      content: String.trim(content),
      reusable: true,
      ownership: :symphony
    )
  end
end
