defmodule Mix.Tasks.Codex.Session.Render do
  use Mix.Task

  alias SymphonyElixir.CodexSessionLogRenderer

  @moduledoc """
  Renders a Codex session NDJSON log into a readable terminal transcript.
  """
  @shortdoc "Render a Codex session log for terminal reading"

  @switches [no_color: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, argv, _invalid} = OptionParser.parse(args, strict: @switches)

    case argv do
      [path] ->
        case CodexSessionLogRenderer.render_file(path, use_color: not Keyword.get(opts, :no_color, false)) do
          :ok -> :ok
          {:error, reason} -> Mix.raise("Failed to render #{Path.expand(path)}: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("Usage: mix codex.session.render [--no-color] <path-to-session.ndjson>")
    end
  end
end
