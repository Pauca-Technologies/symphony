defmodule SymphonyElixir.PersistentWorker.Launcher do
  @moduledoc false

  alias SymphonyElixir.PersistentWorker.Registry

  @internal_mode "__persistent_worker__"

  @doc "Launch a detached worker BEAM for a prepared registry record."
  @spec launch(Registry.manifest()) :: :ok | {:error, term()}
  def launch(%{spec_path: spec_path, log_path: log_path}) do
    with {:ok, executable} <- executable(),
         {:ok, shell} <- required_executable("sh"),
         {:ok, nohup} <- required_executable("nohup"),
         {:ok, setsid_prefix} <- setsid_prefix() do
      command =
        [
          "ERL_FLAGS=#{shell_quote(worker_erl_flags())}",
          shell_quote(nohup),
          setsid_prefix,
          shell_quote(executable),
          shell_quote(@internal_mode),
          shell_quote(spec_path),
          ">>",
          shell_quote(log_path),
          "2>&1",
          "</dev/null",
          "&"
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" ")

      case System.cmd(shell, ["-c", command], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:worker_launch_failed, status, String.trim(output)}}
      end
    end
  rescue
    error -> {:error, {:worker_launch_failed, Exception.message(error)}}
  end

  @doc false
  @spec executable() :: {:ok, Path.t()} | {:error, term()}
  def executable do
    configured = Application.get_env(:symphony_elixir, :persistent_worker_executable)

    candidate =
      case configured do
        path when is_binary(path) and path != "" -> path
        _other -> :escript.script_name() |> to_string()
      end

    expanded = Path.expand(candidate)

    if File.regular?(expanded) do
      {:ok, expanded}
    else
      {:error, {:persistent_worker_executable_not_found, expanded}}
    end
  end

  defp required_executable(name) do
    case System.find_executable(name) do
      nil -> {:error, {:executable_not_found, name}}
      path -> {:ok, path}
    end
  end

  defp setsid_prefix do
    case System.find_executable("setsid") do
      nil -> {:ok, ""}
      path -> {:ok, shell_quote(path)}
    end
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp worker_erl_flags do
    Application.get_env(
      :symphony_elixir,
      :persistent_worker_erl_flags,
      "+S 2:2 +SDcpu 1 +SDio 1 +sbwt none +sbwtdcpu none +sbwtdio none"
    )
  end
end
