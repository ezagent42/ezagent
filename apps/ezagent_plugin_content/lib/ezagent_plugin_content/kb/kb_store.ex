defmodule EzagentPluginContent.Kb.KbStore do
  @moduledoc "KB entry CRUD. Wraps Python MCP script calls."

  @chunk_max_chars 600
  @chunk_min_chars 50

  @spec search(binary(), String.t()) :: [map()]
  def search(kb_dir, query) do
    script = Path.join(kb_dir, "kb_search_mcp.py")
    db = Path.join(kb_dir, "kb.db")

    case System.cmd("uv", ["run", "--script", script, "--db-path", db, "--query", query], stderr_to_stdout: true) do
      {output, 0} -> decode_json_list(output)
      _ -> []
    end
  rescue
    _ -> []
  end

  @spec upsert(binary(), map()) :: :ok | {:error, term()}
  def upsert(kb_dir, entry) do
    script = Path.join(kb_dir, "kb_search_mcp.py")
    db = Path.join(kb_dir, "kb.db")

    case System.cmd(
           "uv",
           [
             "run",
             "--script",
             script,
             "--db-path",
             db,
             "--upsert",
             Jason.encode_to_iodata!(entry) |> IO.iodata_to_binary()
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end

  @spec delete(binary(), String.t()) :: :ok
  def delete(kb_dir, id) do
    script = Path.join(kb_dir, "kb_search_mcp.py")
    db = Path.join(kb_dir, "kb.db")
    System.cmd("uv", ["run", "--script", script, "--db-path", db, "--delete", id], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  @doc "Fetch a URL and add its content as a KB entry. Downloads HTML via curl, strips tags, upserts."
  @spec fetch_url(binary(), String.t()) :: :ok | {:error, term()}
  def fetch_url(kb_dir, url) do
    case System.cmd("curl", ["-sL", "--max-time", "10", url], stderr_to_stdout: true) do
      {html, 0} when byte_size(html) > 100 ->
        hash = :crypto.hash(:sha256, html) |> Base.encode16(case: :lower) |> String.slice(0, 16)
        sources_dir = Path.join(kb_dir, "_sources")
        url_dir = Path.join(sources_dir, "url")
        File.mkdir_p!(url_dir)
        File.write!(Path.join(url_dir, "#{hash}.html"), html)
        text = strip_html(html)

        entry = %{
          "id" => "url:#{hash}",
          "title" => "URL: #{URI.parse(url).host || String.slice(url, 0, 40)}",
          "content" => text,
          "source_type" => "url",
          "source_id" => hash
        }

        chunks = chunk_text(text)

        Enum.each(chunks, fn chunk ->
          chunk_entry = Map.put(entry, "content", chunk)
          upsert(kb_dir, chunk_entry)
        end)

        if chunks == [], do: upsert(kb_dir, entry)

      {output, code} when code != 0 ->
        {:error, "curl exit #{code}: #{String.slice(output, 0, 200)}"}

      {_, 0} ->
        {:error, "Response too short (likely not HTML)"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Ingest an uploaded file into KB. Copies file to _sources/files/, reads text, upserts."
  @spec ingest_file(binary(), binary()) :: :ok | {:error, term()}
  def ingest_file(kb_dir, file_path) do
    unless File.exists?(file_path), do: throw({:error, :enoent})

    fname = Path.basename(file_path)
    sources_dir = Path.join(kb_dir, "_sources")
    files_dir = Path.join(sources_dir, "files")
    File.mkdir_p!(files_dir)
    dest = Path.join(files_dir, fname)
    File.cp!(file_path, dest)

    # Read content based on extension
    content = read_file_content(file_path)
    ext = Path.extname(fname)
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> String.slice(0, 12)

    entry = %{
      "id" => "file:#{hash}",
      "title" => "File: #{fname} (#{ext})",
      "content" => content,
      "source_type" => "file",
      "source_id" => hash
    }

    chunks = chunk_text(content)

    Enum.each(chunks, fn chunk ->
      chunk_entry = Map.put(entry, "content", chunk)
      upsert(kb_dir, chunk_entry)
    end)

    if chunks == [], do: upsert(kb_dir, entry)
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Rebuild KB from sources directory."
  @spec rebuild(binary()) :: :ok | {:error, term()}
  def rebuild(kb_dir) do
    alias EzagentPluginContent.Kb.KbRebuilder
    KbRebuilder.rebuild(kb_dir)
  end

  # -- Private helpers --

  defp chunk_text(text) when is_binary(text) do
    text
    |> String.split(~r/\n\n+/, trim: true)
    |> Enum.flat_map(fn para ->
      if String.length(para) > @chunk_max_chars do
        para
        |> String.split(~r/(?<=[。！？\.\!\?])\s*/, trim: true)
        |> Enum.chunk_every(3)
        |> Enum.map(&Enum.join(&1, ""))
      else
        [para]
      end
    end)
    |> Enum.filter(&(String.length(&1) >= @chunk_min_chars))
    |> Enum.map(&String.slice(&1, 0, @chunk_max_chars))
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/s, "")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/s, "")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  rescue
    _ -> String.slice(html, 0, 5000)
  end

  defp read_file_content(path) do
    ext = Path.extname(path) |> String.downcase()

    case ext do
      ext when ext in [".txt", ".md", ".csv", ".json", ".yaml", ".yml"] ->
        File.read!(path)

      ".pdf" ->
        extract_pdf_text(path)

      ".xlsx" ->
        extract_xlsx_text(path)

      _ ->
        "Binary file: #{Path.basename(path)} (#{ext})"
    end
  rescue
    _ -> "Unable to read file: #{Path.basename(path)}"
  end

  defp extract_pdf_text(path) do
    # Try pdftotext system command
    case System.cmd("pdftotext", ["-layout", path, "-"], stderr_to_stdout: true) do
      {text, 0} when byte_size(text) > 50 -> text
      _ -> "PDF file: #{Path.basename(path)} (text extraction unavailable — install poppler-utils for pdftotext)"
    end
  end

  defp extract_xlsx_text(path) do
    # XLSX files are ZIP archives. Extract shared strings and sheet data.
    try do
      case :zip.extract(String.to_charlist(path), [:memory]) do
        {:ok, files} ->
          # Find shared strings
          strings =
            case List.keyfind(files, ~c'xl/sharedStrings.xml', 0) do
              {_, data} ->
                ~r/<si>.*?<t[^>]*>(.*?)<\/t>.*?<\/si>/s
                |> Regex.scan(to_string(data), capture: :all_but_first)
                |> List.flatten()
                |> Enum.join(" ")

              _ ->
                ""
            end

          # Find sheet data
          sheets =
            files
            |> Enum.filter(fn {name, _} -> to_string(name) =~ ~r/xl\/worksheets\/sheet\d*\.xml/ end)
            |> Enum.map(fn {_, data} ->
              ~r/<v>(.*?)<\/v>/
              |> Regex.scan(to_string(data), capture: :all_but_first)
              |> List.flatten()
              |> Enum.join(" ")
            end)
            |> Enum.join(" | ")

          "#{strings} #{sheets}" |> String.slice(0, 5000)

        _ ->
          "XLSX file: #{Path.basename(path)}"
      end
    rescue
      _ -> "XLSX file: #{Path.basename(path)} (parsing failed)"
    end
  end

  defp decode_json_list(str) do
    case Jason.decode(str) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  rescue
    _ -> []
  end
end
