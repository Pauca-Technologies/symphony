defmodule SymphonyElixir.GitHubAuth do
  @moduledoc """
  Mandatory GitHub App authentication shared by Symphony and interactive users.

  The production provider prepares an isolated `gh` environment in the current
  Git worktree and preflights a repository-scoped installation token. Tests can
  replace the provider through the private `:github_auth_provider` application
  setting; there is deliberately no user-facing disabled mode.
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
  @callback token(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}

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

  @doc "Resolve a cached or freshly minted token for the current repository."
  @spec token(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def token(workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    case provider().token(workspace, opts) do
      {:ok, %{} = token} -> {:ok, token}
      {:error, {:github_auth_failed, _detail} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:github_auth_failed, reason}}
    end
  end

  defp provider do
    Application.get_env(:symphony_elixir, :github_auth_provider, SymphonyElixir.GitHubAuth.Local)
  end
end
