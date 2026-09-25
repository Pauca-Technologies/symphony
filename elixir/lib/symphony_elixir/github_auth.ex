defmodule SymphonyElixir.GitHubAuth do
  @moduledoc """
  Adapter for the mandatory standalone `udp-gh` authentication capability.

  `udp-gh` owns GitHub App credentials, JWT signing, token caching, interactive
  shell activation, and the refreshing `gh` shim. Symphony consumes only its
  versioned, token-free machine contract. Tests can replace the adapter through
  the private `:github_auth_provider` application setting.
  """

  @typedoc "Environment prepared for an agent or lifecycle hook."
  @type env_value :: String.t() | false
  @type session :: %{
          env: [{String.t(), env_value()}],
          repo: String.t(),
          host: String.t(),
          auth_root: Path.t(),
          expires_at: DateTime.t()
        }

  @callback prepare(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}

  @doc "Prepare and preflight GitHub App authentication for a workspace."
  @spec prepare(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def prepare(workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    case provider().prepare(workspace, opts) do
      {:ok, %{} = session} -> {:ok, session}
      {:error, {:github_auth_failed, _detail} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:github_auth_failed, reason}}
    end
  end

  @doc "Return the prepared environment in the format expected by `Port.open/2`."
  @spec port_env(Path.t(), keyword()) ::
          {:ok, [{charlist(), charlist() | false}]} | {:error, term()}
  def port_env(workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    with {:ok, %{env: env}} <- prepare(workspace, opts) do
      {:ok,
       Enum.map(env, fn
         {name, false} -> {String.to_charlist(name), false}
         {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
       end)}
    end
  end

  defp provider do
    Application.get_env(:symphony_elixir, :github_auth_provider, SymphonyElixir.GitHubAuth.External)
  end
end
