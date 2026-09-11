defmodule SymphonyElixir.Config.NoProgress do
  @moduledoc """
  Bounded shadow-mode no-progress thresholds from repository workflow config.
  """

  @defaults %{
    error_repeat_threshold: 3,
    success_repeat_threshold: 8,
    success_no_progress_turns: 2,
    max_fingerprints: 32
  }

  @bounds %{
    error_repeat_threshold: {2, 100},
    success_repeat_threshold: {2, 1_000},
    success_no_progress_turns: {1, 100},
    max_fingerprints: {1, 32}
  }

  @type t :: %{
          error_repeat_threshold: pos_integer(),
          success_repeat_threshold: pos_integer(),
          success_no_progress_turns: pos_integer(),
          max_fingerprints: pos_integer()
        }

  @doc "Read the optional `agent.no_progress` map, applying safe defaults and clamps."
  @spec parse(map()) :: t()
  def parse(config) when is_map(config) do
    raw = config |> value(:agent, %{}) |> value(:no_progress, %{})
    raw = if is_map(raw), do: raw, else: %{}

    Map.new(@defaults, fn {key, default} ->
      {minimum, maximum} = Map.fetch!(@bounds, key)
      {key, bounded(value(raw, key, default), default, minimum, maximum)}
    end)
  end

  defp bounded(value, _default, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp bounded(_value, default, _minimum, _maximum), do: default

  defp value(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp value(_other, _key, default), do: default
end
