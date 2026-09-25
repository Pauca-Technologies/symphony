defmodule SymphonyElixir.ShutdownPolicyStore do
  @moduledoc """
  Persists how the main Symphony process handles live workers during shutdown.
  """

  require Logger

  @default_filename "shutdown-policy.json"
  @default_policy :preserve_workers

  @type policy :: :preserve_workers | :terminate_workers

  @doc "Load the persisted shutdown policy, preserving workers by default."
  @spec load() :: policy()
  def load do
    with {:ok, contents} <- File.read(path()),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, policy} <- decode(decoded) do
      policy
    else
      {:error, :enoent} ->
        @default_policy

      {:error, reason} ->
        Logger.warning("Failed to load shutdown policy: #{inspect(reason)}")
        @default_policy
    end
  end

  @doc "Persist the policy atomically."
  @spec persist(policy()) :: :ok | {:error, term()}
  def persist(policy) when policy in [:preserve_workers, :terminate_workers] do
    target = path()
    temporary = target <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    payload = Jason.encode!(%{"policy" => Atom.to_string(policy)})

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(temporary, payload),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, target) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, reason}
    end
  end

  @doc "Return the configured shutdown-policy path."
  @spec path() :: Path.t()
  def path do
    Application.get_env(:symphony_elixir, :shutdown_policy_path) ||
      Path.join([System.user_home!(), ".symphony", @default_filename])
  end

  defp decode(%{"policy" => "preserve_workers"}), do: {:ok, :preserve_workers}
  defp decode(%{"policy" => "terminate_workers"}), do: {:ok, :terminate_workers}
  defp decode(_decoded), do: {:error, :invalid_shutdown_policy}
end
