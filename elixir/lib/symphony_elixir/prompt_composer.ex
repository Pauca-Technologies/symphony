defmodule SymphonyElixir.PromptComposer do
  @moduledoc """
  Composes typed prompt sections without heuristic instruction deletion.

  Deduplication is deliberately narrow. Only explicit canonical fragments may
  be removed from an explicitly named source section. Exact matches and
  formatting-only equivalents are safe; similar-but-distinct content is kept
  and reported as an ambiguous overlap.
  """

  alias SymphonyElixir.{PromptSection, Utf8}

  @debug_default_max_bytes 32_000

  @type canonical_fragment :: %{
          required(:id) => String.t(),
          required(:content) => String.t(),
          required(:authoritative_section_id) => String.t(),
          optional(:source_section_ids) => [String.t()],
          optional(:allow_format_equivalent) => boolean()
        }

  @type composition :: %{
          prompt: String.t(),
          sections: [map()],
          included_sections: [String.t()],
          section_hashes: %{String.t() => String.t()},
          decisions: [map()],
          diagnostics: [map()],
          suppressed_bytes: non_neg_integer(),
          state: map(),
          debug_sections: [PromptSection.t()]
        }

  @doc "Compose sections and apply only explicitly authorized canonical-fragment suppression."
  @spec compose([PromptSection.t()], keyword()) :: composition()
  def compose(sections, opts \\ []) when is_list(sections) do
    fragments = Keyword.get(opts, :canonical_fragments, [])

    {rendered, decisions, diagnostics} =
      sections
      |> Enum.reject(&blank?/1)
      |> Enum.map_reduce({[], []}, fn section, {all_decisions, all_diagnostics} ->
        {section, section_decisions, section_diagnostics} = suppress_known_fragments(section, fragments)

        {section, {all_decisions ++ section_decisions, all_diagnostics ++ section_diagnostics}}
      end)
      |> then(fn {rendered, {decisions, diagnostics}} -> {rendered, decisions, diagnostics} end)

    prompt = Enum.map_join(rendered, "\n\n", & &1.content)
    metadata = Enum.map(rendered, &section_metadata/1)
    suppressed_bytes = Enum.sum(Enum.map(decisions, & &1.suppressed_bytes))

    %{
      prompt: prompt,
      sections: metadata,
      included_sections: Enum.map(rendered, & &1.id),
      section_hashes: Map.new(rendered, &{&1.id, &1.hash}),
      decisions: decisions,
      diagnostics: diagnostics,
      suppressed_bytes: suppressed_bytes,
      state: Map.new(rendered, &{&1.id, reusable_identity(&1)}),
      debug_sections: rendered
    }
  end

  @doc "Return unchanged reusable identities from a prior composition state."
  @spec reused_sections(map(), [PromptSection.t()]) :: {[map()], [PromptSection.t()]}
  def reused_sections(previous_state, sections) when is_map(previous_state) and is_list(sections) do
    Enum.reduce(sections, {[], []}, fn section, {reused, changed} ->
      case Map.get(previous_state, section.id) do
        %{hash: hash, version: version} = identity
        when section.reusable and hash == section.hash and version == section.version ->
          {[identity | reused], changed}

        _changed ->
          {reused, [section | changed]}
      end
    end)
    |> then(fn {reused, changed} -> {Enum.reverse(reused), Enum.reverse(changed)} end)
  end

  @doc "Render a bounded prompt-debug view with provenance boundaries and configured secret assignments redacted."
  @spec debug_render(composition(), keyword()) :: String.t()
  def debug_render(composition, opts \\ []) when is_map(composition) do
    fields = Keyword.get(opts, :redact_fields, [])
    max_bytes = max(Keyword.get(opts, :max_bytes, @debug_default_max_bytes), 0)

    rendered =
      composition.debug_sections
      |> Enum.map_join("\n\n", fn section ->
        """
        <<<SYMPHONY_PROMPT_SECTION id=#{section.id} type=#{section.type} source=#{section.source} version=#{section.version} hash=#{section.hash} bytes=#{section.bytes} estimated_tokens=#{section.estimated_tokens}>>>
        #{redact_text(section.content, fields)}
        <<<END_SYMPHONY_PROMPT_SECTION id=#{section.id}>>>
        """
        |> String.trim()
      end)

    if byte_size(rendered) > max_bytes do
      suffix = "\n…[prompt debug truncated sha256=#{sha256(rendered)}]"

      if byte_size(suffix) >= max_bytes do
        Utf8.safe_byte_prefix(suffix, max_bytes)
      else
        prefix_bytes = max_bytes - byte_size(suffix)
        Utf8.safe_byte_prefix(rendered, prefix_bytes) <> suffix
      end
    else
      rendered
    end
  end

  defp suppress_known_fragments(%PromptSection{} = section, fragments) do
    Enum.reduce(fragments, {section, [], []}, fn fragment, {current, decisions, diagnostics} ->
      apply_fragment_decision(
        section.id,
        current,
        fragment,
        decisions,
        diagnostics
      )
    end)
  end

  defp apply_fragment_decision(section_id, current, fragment, decisions, diagnostics) do
    if authorized_source?(fragment, current.id) do
      apply_authorized_fragment(section_id, current, fragment, decisions, diagnostics)
    else
      {current, decisions, diagnostics}
    end
  end

  defp apply_authorized_fragment(section_id, current, fragment, decisions, diagnostics) do
    case suppress_fragment(current.content, fragment) do
      {:suppressed, content, bytes, match_kind} ->
        updated = rebuild(current, content)

        decision = %{
          section_id: section_id,
          canonical_fragment_id: fragment.id,
          authoritative_section_id: fragment.authoritative_section_id,
          decision: "suppressed",
          reason: "canonical_#{match_kind}_duplicate",
          suppressed_bytes: bytes,
          fragment_hash: sha256(fragment.content)
        }

        {updated, decisions ++ [decision], diagnostics}

      :ambiguous ->
        diagnostic = %{
          section_id: section_id,
          canonical_fragment_id: fragment.id,
          decision: "preserved",
          reason: "ambiguous_overlap"
        }

        {current, decisions, diagnostics ++ [diagnostic]}

      :distinct ->
        {current, decisions, diagnostics}
    end
  end

  defp suppress_fragment(content, %{content: fragment} = canonical)
       when is_binary(fragment) and fragment != "" do
    cond do
      String.contains?(content, fragment) ->
        replacement = canonical_reference(canonical)
        count = length(:binary.matches(content, fragment))
        {:suppressed, String.replace(content, fragment, replacement), count * byte_size(fragment), "exact"}

      Map.get(canonical, :allow_format_equivalent, true) ->
        suppress_format_equivalent(content, canonical)

      true ->
        :distinct
    end
  end

  defp suppress_fragment(_content, _fragment), do: :distinct

  defp suppress_format_equivalent(content, canonical) do
    chunks = Regex.split(~r/(?:\r?\n\s*){2,}/, content, include_captures: true, trim: false)
    target = normalize_formatting(canonical.content)

    {chunks, count, bytes, ambiguous?} =
      Enum.reduce(chunks, {[], 0, 0, false}, fn chunk, {acc, count, bytes, ambiguous?} ->
        normalized = normalize_formatting(chunk)

        cond do
          normalized != "" and normalized == target ->
            {[canonical_reference(canonical) | acc], count + 1, bytes + byte_size(chunk), ambiguous?}

          ambiguous_overlap?(normalized, target) ->
            {[chunk | acc], count, bytes, true}

          true ->
            {[chunk | acc], count, bytes, ambiguous?}
        end
      end)

    cond do
      count > 0 -> {:suppressed, chunks |> Enum.reverse() |> IO.iodata_to_binary(), bytes, "format_equivalent"}
      ambiguous? -> :ambiguous
      true -> :distinct
    end
  end

  defp normalize_formatting(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/(^|\n)\s*(?:[#]{1,6}|[-*+>]|\d+[.)])\s*/u, " ")
    |> String.replace(~r/[`*_~]/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp ambiguous_overlap?("", _target), do: false
  defp ambiguous_overlap?(_normalized, ""), do: false

  defp ambiguous_overlap?(normalized, target) do
    left = normalized |> String.split() |> MapSet.new()
    right = target |> String.split() |> MapSet.new()
    union = MapSet.union(left, right) |> MapSet.size()

    union >= 8 and MapSet.intersection(left, right) |> MapSet.size() |> Kernel./(union) >= 0.8
  end

  defp authorized_source?(fragment, section_id) do
    section_id in Map.get(fragment, :source_section_ids, ["repository.workflow"])
  end

  defp canonical_reference(fragment) do
    "[Duplicate omitted; `#{fragment.authoritative_section_id}` is authoritative.]"
  end

  defp rebuild(section, content) do
    PromptSection.new(
      id: section.id,
      type: section.type,
      source: section.source,
      version: section.version,
      content: content,
      reusable: section.reusable,
      ownership: section.ownership
    )
  end

  defp section_metadata(section) do
    Map.take(section, [
      :id,
      :type,
      :source,
      :version,
      :hash,
      :bytes,
      :estimated_tokens,
      :reusable,
      :ownership
    ])
  end

  defp reusable_identity(section) do
    section
    |> section_metadata()
    |> Map.take([:id, :source, :version, :hash, :bytes, :estimated_tokens, :reusable])
  end

  defp redact_text(text, fields) do
    Enum.reduce(fields, text, fn field, redacted ->
      escaped = Regex.escape(to_string(field))
      pattern = ~s/(?im)(^|[{\s,])(["']?#{escaped}["']?\s*[:=]\s*).*$/

      Regex.replace(
        Regex.compile!(pattern),
        redacted,
        "\\1\\2[REDACTED]"
      )
    end)
  end

  defp blank?(%PromptSection{content: content}), do: String.trim(content) == ""
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
