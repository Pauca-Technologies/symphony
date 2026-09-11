defmodule SymphonyElixir.RegressionCorpus do
  @moduledoc "Bounded telemetry scanning and operator-managed regression corpus staging."

  alias SymphonyElixir.RegressionCandidate

  @max_files 60
  @max_rows 50_000
  @max_source_bytes 256 * 1_024 * 1_024
  @max_expanded_bytes 256 * 1_024 * 1_024
  @max_line_bytes 16_384
  @max_bundle_bytes 1_048_576
  @chunk_bytes 8_192
  @source_root Path.expand("../..", __DIR__)
  @filename ~r/\A(\d{4}-\d{2}-\d{2})\.jsonl(?:\.gz)?\z/
  @corpus_filename ~r/\Argc-corpus-[0-9a-f]{32}(?:\.pending)?\.json\z/

  @type diagnostic :: %{
          required(String.t()) => non_neg_integer() | map()
        }

  @doc "Scan an exact 7- or 30-day telemetry window with fixed resource bounds."
  @spec scan(Path.t(), Date.t(), keyword()) ::
          {:ok, %{corpus: map(), diagnostics: diagnostic()}} | {:error, :invalid_scan | :invalid_window}
  def scan(root, today, opts \\ [])

  def scan(root, %Date{} = today, opts) when is_binary(root) and is_list(opts) do
    with true <- absolute_path?(root),
         window when window in [7, 30] <- Keyword.get(opts, :window_days, 7) do
      {files, diagnostics} = select_files(root, Date.add(today, 1 - window), today)
      source_limit = bounded_limit(Keyword.get(opts, :source_byte_limit), @max_source_bytes)
      expanded_limit = bounded_limit(Keyword.get(opts, :expanded_byte_limit), @max_expanded_bytes)
      {events, diagnostics} = scan_files(files, diagnostics, source_limit, expanded_limit)

      {:ok,
       %{
         corpus: RegressionCandidate.build(events, window_days: window),
         diagnostics: Map.put(diagnostics, "window_days", window)
       }}
    else
      false -> {:error, :invalid_scan}
      _invalid_window -> {:error, :invalid_window}
    end
  rescue
    _invalid -> {:error, :invalid_scan}
  end

  def scan(_root, _today, _opts), do: {:error, :invalid_scan}

  @doc "Atomically export a generated pending corpus to an explicit private staging directory."
  @spec export(map(), Path.t()) ::
          {:ok, %{status: :written | :unchanged, path: Path.t(), corpus_id: String.t(), bytes: non_neg_integer()}}
          | {:error, atom()}
  def export(corpus, staging_root) when is_map(corpus) and is_binary(staging_root) do
    with true <- absolute_path?(staging_root) and outside_source_tree?(staging_root),
         "pending_review" <- corpus["state"],
         id when is_binary(id) <- safe_corpus_id(corpus["corpus_id"]),
         {:ok, _report} <- RegressionCandidate.verify(corpus),
         {:ok, encoded} <- Jason.encode(corpus),
         true <- byte_size(encoded) <= @max_bundle_bytes,
         :ok <- ensure_private_directory(staging_root) do
      path = Path.join(staging_root, "#{id}.pending.json")
      export_bytes(path, encoded, id)
    else
      false -> {:error, :invalid_export}
      nil -> {:error, :invalid_export}
      {:error, _reason} -> {:error, :invalid_export}
      _invalid -> {:error, :invalid_export}
    end
  end

  def export(_corpus, _staging_root), do: {:error, :invalid_export}

  @doc "Read and structurally verify one bounded regular corpus file."
  @spec read(Path.t()) :: {:ok, map()} | {:error, atom()}
  def read(path) when is_binary(path) do
    with true <- absolute_path?(path),
         true <- Regex.match?(@corpus_filename, Path.basename(path)),
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular,
         {:ok, encoded} <- read_bounded(path),
         true <- byte_size(encoded) <= @max_bundle_bytes,
         {:ok, corpus} when is_map(corpus) <- Jason.decode(encoded),
         {:ok, _report} <- RegressionCandidate.verify(corpus) do
      {:ok, corpus}
    else
      _invalid -> {:error, :invalid_corpus_file}
    end
  end

  def read(_path), do: {:error, :invalid_corpus_file}

  defp select_files(root, from, to) do
    diagnostics = diagnostics()

    with {:ok, stat} <- File.lstat(root),
         true <- stat.type == :directory,
         {:ok, entries} <- File.ls(root) do
      files =
        entries
        |> Enum.flat_map(&dated_path(root, &1, from, to))
        |> Enum.sort_by(fn {date, plain?, _path} -> {date, plain?} end, :desc)
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 2))

      selected = Enum.take(files, @max_files)
      {selected, %{diagnostics | "files_selected" => length(selected)}}
    else
      _unavailable -> {[], omit(diagnostics, "source_unavailable")}
    end
  end

  defp dated_path(root, name, from, to) do
    with [_, date_string] <- Regex.run(@filename, name),
         {:ok, date} <- Date.from_iso8601(date_string),
         true <- Date.compare(date, from) != :lt and Date.compare(date, to) != :gt do
      [{date, not String.ends_with?(name, ".gz"), Path.join(root, name)}]
    else
      _invalid -> []
    end
  end

  defp scan_files(files, diagnostics, source_limit, expanded_limit) do
    Enum.reduce_while(files, {[], diagnostics}, &scan_next_file(&1, &2, source_limit, expanded_limit))
  end

  defp scan_next_file(path, {events, diagnostics}, source_limit, expanded_limit) do
    limits =
      {@max_rows - diagnostics["rows_seen"], source_limit - diagnostics["source_bytes"], expanded_limit - diagnostics["expanded_bytes"]}

    case scan_file(path, elem(limits, 0), elem(limits, 1), elem(limits, 2)) do
      {:ok, rows, stats} ->
        scanned_file(rows, stats, events, diagnostics)

      {:error, code, rows, stats} when code in ["source_bytes_exceeded", "expanded_bytes_exceeded"] ->
        {:halt, {rows ++ events, stats |> merge_stats(diagnostics) |> omit(code)}}

      {:error, code, _rows, stats} ->
        {:cont, {events, stats |> merge_stats(diagnostics) |> omit(code)}}
    end
  end

  defp scanned_file(rows, stats, events, diagnostics) do
    next = {rows ++ events, merge_stats(diagnostics, stats)}
    if stats.row_limit, do: {:halt, {elem(next, 0), omit(elem(next, 1), "row_limit_reached")}}, else: {:cont, next}
  end

  defp scan_file(path, row_limit, source_limit, expanded_limit) do
    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        if String.ends_with?(path, ".gz") do
          scan_gzip(io, row_limit, source_limit, expanded_limit)
        else
          scan_plain(io, row_limit, source_limit, expanded_limit)
        end
      after
        File.close(io)
      end
    else
      _invalid -> {:error, "unsafe_or_unreadable_file", [], empty_stats()}
    end
  end

  defp scan_plain(io, row_limit, source_limit, expanded_limit) do
    state = line_state(row_limit)

    case read_plain_chunks(io, state, source_limit, expanded_limit) do
      {:ok, state} -> finish_lines(state)
      {:error, code, state} -> {:error, code, Enum.reverse(state.events), stats(state)}
    end
  end

  defp read_plain_chunks(io, state, source_limit, expanded_limit) do
    case IO.binread(io, @chunk_bytes) do
      chunk when is_binary(chunk) -> consume_plain_chunk(io, chunk, state, source_limit, expanded_limit)
      other -> if(other == :eof, do: {:ok, state}, else: {:error, "read_failed", state})
    end
  end

  defp consume_plain_chunk(io, chunk, state, source_limit, expanded_limit) do
    bytes = byte_size(chunk)

    cond do
      state.source_bytes + bytes > source_limit ->
        {:error, "source_bytes_exceeded", state}

      state.expanded_bytes + bytes > expanded_limit ->
        {:error, "expanded_bytes_exceeded", state}

      true ->
        state = %{state | source_bytes: state.source_bytes + bytes, expanded_bytes: state.expanded_bytes + bytes}

        case consume_lines(chunk, state) do
          %{row_limit: true} = state -> {:ok, state}
          state -> read_plain_chunks(io, state, source_limit, expanded_limit)
        end
    end
  end

  defp scan_gzip(io, row_limit, source_limit, expanded_limit) do
    zlib = :zlib.open()

    try do
      :ok = :zlib.inflateInit(zlib, 31)

      case read_gzip_chunks(io, zlib, line_state(row_limit), source_limit, expanded_limit) do
        {:ok, %{row_limit: true} = state} ->
          finish_lines(state)

        {:ok, state} ->
          :ok = :zlib.inflateEnd(zlib)
          finish_lines(state)

        {:error, code, state} ->
          {:error, code, Enum.reverse(state.events), stats(state)}
      end
    catch
      _kind, _reason -> {:error, "invalid_gzip", [], empty_stats()}
    after
      :zlib.close(zlib)
    end
  end

  defp read_gzip_chunks(io, zlib, state, source_limit, expanded_limit) do
    case IO.binread(io, @chunk_bytes) do
      chunk when is_binary(chunk) ->
        consume_gzip_chunk(io, zlib, chunk, state, source_limit, expanded_limit)

      other ->
        if(other == :eof, do: {:ok, state}, else: {:error, "read_failed", state})
    end
  end

  defp consume_gzip_chunk(io, zlib, chunk, state, source_limit, expanded_limit) do
    if state.source_bytes + byte_size(chunk) > source_limit do
      {:error, "source_bytes_exceeded", state}
    else
      state = %{state | source_bytes: state.source_bytes + byte_size(chunk)}

      case inflate(zlib, chunk, state, expanded_limit) do
        {:ok, %{row_limit: true} = state} -> {:ok, state}
        {:ok, state} -> read_gzip_chunks(io, zlib, state, source_limit, expanded_limit)
        error -> error
      end
    end
  end

  defp inflate(zlib, input, state, expanded_limit) do
    case :zlib.safeInflate(zlib, input) do
      {status, output} when status in [:continue, :finished] ->
        consume_inflated(zlib, status, IO.iodata_to_binary(output), state, expanded_limit)
    end
  catch
    _kind, _reason -> {:error, "invalid_gzip", state}
  end

  defp consume_inflated(zlib, status, output, state, expanded_limit) do
    if state.expanded_bytes + byte_size(output) > expanded_limit do
      {:error, "expanded_bytes_exceeded", state}
    else
      state = consume_lines(output, %{state | expanded_bytes: state.expanded_bytes + byte_size(output)})

      if status == :continue and not state.row_limit,
        do: inflate(zlib, <<>>, state, expanded_limit),
        else: {:ok, state}
    end
  end

  defp consume_lines(chunk, %{dropping_line: true} = state) do
    case :binary.match(chunk, "\n") do
      {_offset, 1} = match -> consume_data(binary_part(chunk, elem(match, 0) + 1, byte_size(chunk) - elem(match, 0) - 1), %{state | dropping_line: false})
      :nomatch -> state
    end
  end

  defp consume_lines(chunk, state), do: consume_data(state.buffer <> chunk, %{state | buffer: ""})

  defp consume_data(_data, %{row_limit: true} = state), do: state

  defp consume_data(data, state) do
    case :binary.match(data, "\n") do
      {offset, 1} ->
        <<line::binary-size(offset), _newline, rest::binary>> = data
        state = if byte_size(line) > @max_line_bytes, do: omit_line(state), else: decode_line(line, state)
        consume_data(rest, state)

      :nomatch when byte_size(data) > @max_line_bytes ->
        %{omit_line(state) | dropping_line: true}

      :nomatch ->
        %{state | buffer: data}
    end
  end

  defp decode_line(_line, %{rows_seen: rows, row_limit_count: rows} = state), do: %{state | row_limit: true}

  defp decode_line(line, state) do
    state = %{state | rows_seen: state.rows_seen + 1}

    case Jason.decode(line) do
      {:ok, event} when is_map(event) -> %{state | events: [event | state.events], rows_decoded: state.rows_decoded + 1}
      _malformed -> %{state | malformed_rows: state.malformed_rows + 1}
    end
  end

  defp omit_line(%{rows_seen: rows, row_limit_count: rows} = state), do: %{state | row_limit: true, buffer: ""}

  defp omit_line(state),
    do: %{state | overlong_lines: state.overlong_lines + 1, rows_seen: state.rows_seen + 1, buffer: ""}

  defp finish_lines(%{row_limit: true} = state), do: {:ok, Enum.reverse(state.events), stats(state)}

  defp finish_lines(%{dropping_line: true} = state),
    do: {:ok, Enum.reverse(state.events), stats(state)}

  defp finish_lines(%{buffer: ""} = state), do: {:ok, Enum.reverse(state.events), stats(state)}

  defp finish_lines(state) do
    state = decode_line(state.buffer, %{state | buffer: ""})
    {:ok, Enum.reverse(state.events), stats(state)}
  end

  defp line_state(row_limit) do
    %{
      buffer: "",
      dropping_line: false,
      events: [],
      rows_seen: 0,
      rows_decoded: 0,
      malformed_rows: 0,
      overlong_lines: 0,
      source_bytes: 0,
      expanded_bytes: 0,
      row_limit_count: row_limit,
      row_limit: false
    }
  end

  defp stats(state) do
    %{
      files_read: 1,
      rows_seen: state.rows_seen,
      rows_decoded: state.rows_decoded,
      malformed_rows: state.malformed_rows,
      overlong_lines: state.overlong_lines,
      source_bytes: state.source_bytes,
      expanded_bytes: state.expanded_bytes,
      row_limit: state.row_limit
    }
  end

  defp empty_stats do
    %{files_read: 0, rows_seen: 0, rows_decoded: 0, malformed_rows: 0, overlong_lines: 0, source_bytes: 0, expanded_bytes: 0, row_limit: false}
  end

  defp diagnostics do
    %{
      "files_selected" => 0,
      "files_read" => 0,
      "rows_seen" => 0,
      "rows_decoded" => 0,
      "malformed_rows" => 0,
      "overlong_lines" => 0,
      "source_bytes" => 0,
      "expanded_bytes" => 0,
      "omissions" => %{}
    }
  end

  defp merge_stats(stats, diagnostics) when is_map_key(stats, :files_read) do
    Enum.reduce(~w(files_read rows_seen rows_decoded malformed_rows overlong_lines source_bytes expanded_bytes), diagnostics, fn key, acc ->
      Map.update!(acc, key, &(&1 + stats[String.to_existing_atom(key)]))
    end)
  end

  defp merge_stats(diagnostics, stats), do: merge_stats(stats, diagnostics)

  defp omit(diagnostics, code) do
    update_in(diagnostics, ["omissions", code], &((&1 || 0) + 1))
  end

  defp export_bytes(path, encoded, id), do: atomic_write(path, encoded, id)

  defp bounded_existing(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.size <= @max_bundle_bytes do
      read_bounded(path)
    else
      _unsafe_or_missing -> {:error, :unsafe_file}
    end
  end

  defp atomic_write(path, encoded, id) do
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    result =
      with :ok <- File.write(temporary, encoded, [:binary, :exclusive]),
           :ok <- File.chmod(temporary, 0o600) do
        publish_without_replace(temporary, path, encoded, id)
      else
        _error -> {:error, :export_failed}
      end

    _ = File.rm(temporary)
    result
  end

  defp publish_without_replace(temporary, path, encoded, id) do
    case File.ln(temporary, path) do
      :ok -> {:ok, %{status: :written, path: path, corpus_id: id, bytes: byte_size(encoded)}}
      {:error, _reason} -> resolve_existing(path, encoded, id)
    end
  end

  defp resolve_existing(path, encoded, id) do
    case bounded_existing(path) do
      {:ok, ^encoded} -> {:ok, %{status: :unchanged, path: path, corpus_id: id, bytes: byte_size(encoded)}}
      {:ok, _different} -> {:error, :conflicting_export}
      {:error, _reason} -> {:error, :invalid_export}
    end
  end

  defp ensure_private_directory(path) do
    with true <- no_symlink_components?(path),
         {:ok, %{type: :directory, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o700 do
      :ok
    else
      _unsafe_or_unreadable -> {:error, :unsafe_directory}
    end
  end

  defp no_symlink_components?(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while(nil, fn component, parent ->
      current = if parent, do: Path.join(parent, component), else: component

      case File.lstat(current) do
        {:ok, %{type: :symlink}} -> {:halt, false}
        {:ok, _stat} -> {:cont, current}
        {:error, _reason} -> {:halt, false}
      end
    end)
    |> is_binary()
  end

  defp safe_corpus_id("rgc-corpus-" <> digest = id) when byte_size(digest) == 32 do
    if Regex.match?(~r/\A[0-9a-f]{32}\z/, digest), do: id
  end

  defp safe_corpus_id(_invalid), do: nil

  defp read_bounded(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(io, @max_bundle_bytes + 1) do
          data when is_binary(data) and byte_size(data) <= @max_bundle_bytes -> {:ok, data}
          _oversized_or_unreadable -> {:error, :invalid_size}
        end
      after
        File.close(io)
      end
    end
  end

  defp outside_source_tree?(path) do
    expanded = Path.expand(path)
    expanded != @source_root and not String.starts_with?(expanded, @source_root <> "/")
  end

  defp absolute_path?(path), do: String.valid?(path) and Path.type(path) == :absolute

  defp bounded_limit(value, hard_max) when is_integer(value) and value > 0, do: min(value, hard_max)
  defp bounded_limit(_value, hard_max), do: hard_max
end
