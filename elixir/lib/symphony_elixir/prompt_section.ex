defmodule SymphonyElixir.PromptSection do
  @moduledoc """
  A typed, provenance-aware unit of content injected into an agent prompt.

  Section IDs describe semantic ownership and stay stable across turns. The
  content hash describes one exact rendering of that section; source and
  version identify where that rendering came from.
  """

  @enforce_keys [:id, :type, :source, :version, :content]
  defstruct [
    :id,
    :type,
    :source,
    :version,
    :content,
    :hash,
    :bytes,
    :estimated_tokens,
    reusable: false,
    ownership: :unknown
  ]

  @type ownership :: :linear | :repository | :symphony | :generated | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          type: atom(),
          source: String.t(),
          version: String.t(),
          content: String.t(),
          hash: String.t(),
          bytes: non_neg_integer(),
          estimated_tokens: non_neg_integer(),
          reusable: boolean(),
          ownership: ownership()
        }

  @doc "Build a section and derive its exact size and identity metadata."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    content = attrs |> Map.fetch!(:content) |> IO.iodata_to_binary() |> String.trim()
    bytes = byte_size(content)

    struct!(__MODULE__,
      id: attrs |> Map.fetch!(:id) |> to_string(),
      type: Map.fetch!(attrs, :type),
      source: attrs |> Map.fetch!(:source) |> to_string(),
      version: attrs |> Map.fetch!(:version) |> to_string(),
      content: content,
      hash: sha256(content),
      bytes: bytes,
      estimated_tokens: estimated_tokens(bytes),
      reusable: Map.get(attrs, :reusable, false),
      ownership: Map.get(attrs, :ownership, :unknown)
    )
  end

  @doc "Return the conservative, tokenizer-independent token estimate used in telemetry."
  @spec estimated_tokens(non_neg_integer()) :: non_neg_integer()
  def estimated_tokens(0), do: 0
  def estimated_tokens(bytes) when is_integer(bytes) and bytes > 0, do: div(bytes + 2, 3)

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
