defmodule SymphonyElixir.Utf8 do
  @moduledoc false

  @doc "Return a byte-bounded prefix without splitting a UTF-8 codepoint."
  @spec safe_byte_prefix(binary(), non_neg_integer()) :: binary()
  def safe_byte_prefix(value, max_bytes)
      when is_binary(value) and is_integer(max_bytes) and max_bytes >= 0 do
    if byte_size(value) <= max_bytes do
      value
    else
      valid_prefix(value, max_bytes)
    end
  end

  defp valid_prefix(_value, 0), do: ""

  defp valid_prefix(value, bytes) do
    prefix = binary_part(value, 0, bytes)
    if String.valid?(prefix), do: prefix, else: valid_prefix(value, bytes - 1)
  end
end
