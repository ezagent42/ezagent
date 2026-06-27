defmodule EzagentPluginKb.Store do
  @moduledoc """
  The separate, PORTABLE per-KB sqlite store — `exqlite` used DIRECTLY (NOT a
  2nd `Ecto.Repo`; one sqlite file PER kb-agent does not fit a single bound
  repo). This module is pure: it knows nothing about agents, dispatch, or the
  framework — it opens a file path, runs FTS5 SQL, and closes. The framework
  half (path resolution, transient lifecycle, caps) lives in
  `Ezagent.Behavior.Kb`.

  ## What the constraint demands (SPEC rev 3)

  KB corpus + index bytes live WHOLLY in the sqlite file — zero rows in
  ezagent's Postgres, zero ezagent migrations. Copy `kb.sqlite` and you have
  moved/backed-up/inspected the entire corpus (portability — `export/2`).

  ## Schema

  One FTS5 virtual table `chunks(text, source_uri UNINDEXED, chunk_index
  UNINDEXED)` with `tokenize='trigram'`. trigram is bilingual EN/zh by
  construction: it indexes overlapping 3-character grams across ANY script, so
  Chinese (which `unicode61` does NOT segment on whitespace) is searchable with
  zero extra extension. A `user_version` PRAGMA stamps the schema so a future
  tokenizer change is detectable (re-index path deferred).

  ## Operational policy (SPEC §4.2.1)

  * `journal_mode = DELETE` — true single-file simplicity. KB writes are
    serialized through the kb-agent's Kind mailbox, so concurrent
    read-during-write (WAL's only edge) is not needed, and a single-file copy
    is always complete (no `-wal` sidecar to miss). This makes portability
    (`export/2`) a trivial file copy with no checkpoint dance.
  * `busy_timeout` (default 5s) so an OUT-OF-BAND reader (an external sqlite
    tool opening the portable file) does not error a query.

  ## SQL safety (SPEC §6.2)

  Every value (the FTS5 `MATCH` operand, every INSERT value, the `k` limit) is
  a BOUND parameter via prepared statements — user input is data, never
  concatenated into SQL.
  """

  alias Exqlite.Sqlite3

  @typedoc "An open sqlite database handle (an opaque exqlite NIF resource)."
  @type db :: Sqlite3.db()

  @typedoc "A retrieval hit with provenance (SPEC §5.4)."
  @type hit :: %{
          text: String.t(),
          score: float(),
          source_uri: String.t(),
          chunk_id: integer()
        }

  # Schema generation — bumped if the FTS5 schema/tokenizer changes (then a
  # populated file needs the deferred re-index path).
  @schema_version 1
  @default_busy_timeout_ms 5_000

  @doc """
  Open (creating + bootstrapping if absent) the per-KB sqlite file at `path`.

  Idempotent: on an existing file it reuses the table and re-applies the
  operational pragmas. Returns an open handle the caller MUST eventually
  `close/1` (the Behavior holds it as a transient and closes it on deactivate).
  """
  @spec open(String.t()) :: {:ok, db()} | {:error, term()}
  def open(path) when is_binary(path) do
    with :ok <- ensure_parent_dir(path),
         {:ok, db} <- Sqlite3.open(path),
         :ok <- apply_pragmas(db),
         :ok <- bootstrap_schema(db) do
      {:ok, db}
    end
  end

  @doc "Close an open handle. Safe on `nil`."
  @spec close(db() | nil) :: :ok
  def close(nil), do: :ok
  def close(db), do: Sqlite3.close(db)

  @doc """
  Ingest one source's chunks, REPLACING any prior rows for the same
  `source_uri` (single-source create/overwrite contract, SPEC §4.4) — atomic:
  delete-by-source then insert, in one transaction, so a re-ingest never
  silently duplicates and a mid-ingest failure leaves the prior source intact.

  `chunks` is a list of `{chunk_index, text}` tuples (the caller chunked the
  source). Returns the number of chunks inserted.
  """
  @spec ingest(db(), String.t(), [{non_neg_integer(), String.t()}]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def ingest(db, source_uri, chunks)
      when is_binary(source_uri) and is_list(chunks) do
    with :ok <- Sqlite3.execute(db, "BEGIN"),
         :ok <- delete_source(db, source_uri),
         {:ok, n} <- insert_chunks(db, source_uri, chunks),
         :ok <- Sqlite3.execute(db, "COMMIT") do
      {:ok, n}
    else
      {:error, _} = err ->
        _ = Sqlite3.execute(db, "ROLLBACK")
        err
    end
  end

  @doc """
  FTS5 keyword query — returns the top-`k` hits ranked by bm25, each with
  provenance (SPEC §5.4).

  `query_string` is NORMALIZED to the FTS5 grammar before MATCH (SPEC §4.2.2):
  it is split into terms and each term is wrapped as a quoted FTS5 string
  (`"term"`), so SQL/FTS5 metacharacters (`"`, `*`, `AND`, `;`) are treated as
  LITERAL data — no error, no injection, lexical matches only. The MATCH
  operand and `k` are bound parameters.
  """
  @spec query(db(), String.t(), pos_integer()) :: {:ok, [hit()]} | {:error, term()}
  def query(db, query_string, k)
      when is_binary(query_string) and is_integer(k) and k > 0 do
    case normalize_match(query_string) do
      "" ->
        # No usable terms (e.g. all sub-trigram noise) → empty result, not an
        # error (SPEC §8.4d: metacharacter input never errors).
        {:ok, []}

      match ->
        sql = """
        SELECT rowid, text, source_uri, bm25(chunks) AS score
        FROM chunks
        WHERE chunks MATCH ?
        ORDER BY score
        LIMIT ?
        """

        with {:ok, stmt} <- Sqlite3.prepare(db, sql),
             :ok <- Sqlite3.bind(stmt, [match, k]),
             {:ok, rows} <- Sqlite3.fetch_all(db, stmt),
             :ok <- Sqlite3.release(db, stmt) do
          {:ok, Enum.map(rows, &row_to_hit/1)}
        end
    end
  end

  @doc """
  Export a consistent, self-contained copy of the store to `dest_path` — the
  PORTABILITY operation (SPEC §8.9). Because `journal_mode = DELETE` keeps the
  whole DB in the one main file (no `-wal` sidecar), a self-contained copy is a
  plain file copy. We additionally `PRAGMA wal_checkpoint(TRUNCATE)` first so
  the call is correct even if a future tier flips to WAL mode (defensive — a
  no-op under DELETE journaling).

  The copied file is independently openable + queryable WITHOUT the ezagent app
  (proven in the portability test by opening it as a second handle).
  """
  @spec export(db(), String.t()) :: :ok | {:error, term()}
  def export(db, dest_path) when is_binary(dest_path) do
    # Defensive checkpoint (no-op under DELETE journaling; correct under WAL).
    _ = Sqlite3.execute(db, "PRAGMA wal_checkpoint(TRUNCATE)")

    with [src_path] <- db_file_path(db),
         :ok <- ensure_parent_dir(dest_path),
         {:ok, _bytes} <- File.copy(src_path, dest_path) do
      :ok
    else
      {:error, _} = err -> err
      other -> {:error, {:export_failed, other}}
    end
  end

  @doc "The on-disk file path of the `main` database of an open handle."
  @spec db_file_path(db()) :: [String.t()]
  def db_file_path(db) do
    case Sqlite3.prepare(db, "PRAGMA database_list") do
      {:ok, stmt} ->
        {:ok, rows} = Sqlite3.fetch_all(db, stmt)
        _ = Sqlite3.release(db, stmt)
        for [_seq, "main", file] <- rows, is_binary(file) and file != "", do: file

      {:error, _} ->
        []
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp ensure_parent_dir(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp apply_pragmas(db) do
    with :ok <- Sqlite3.set_busy_timeout(db, @default_busy_timeout_ms),
         :ok <- Sqlite3.execute(db, "PRAGMA journal_mode=DELETE"),
         :ok <- Sqlite3.execute(db, "PRAGMA foreign_keys=ON") do
      :ok
    end
  end

  defp bootstrap_schema(db) do
    create = """
    CREATE VIRTUAL TABLE IF NOT EXISTS chunks
    USING fts5(text, source_uri UNINDEXED, chunk_index UNINDEXED, tokenize='trigram')
    """

    with :ok <- Sqlite3.execute(db, create),
         :ok <- Sqlite3.execute(db, "PRAGMA user_version=#{@schema_version}") do
      :ok
    end
  end

  defp delete_source(db, source_uri) do
    with {:ok, stmt} <- Sqlite3.prepare(db, "DELETE FROM chunks WHERE source_uri = ?"),
         :ok <- Sqlite3.bind(stmt, [source_uri]),
         :done <- Sqlite3.step(db, stmt),
         :ok <- Sqlite3.release(db, stmt) do
      :ok
    else
      {:error, _} = err -> err
      other -> {:error, {:delete_failed, other}}
    end
  end

  defp insert_chunks(db, source_uri, chunks) do
    sql = "INSERT INTO chunks(text, source_uri, chunk_index) VALUES (?, ?, ?)"

    with {:ok, stmt} <- Sqlite3.prepare(db, sql) do
      result =
        Enum.reduce_while(chunks, {:ok, 0}, fn {idx, text}, {:ok, n} ->
          with :ok <- Sqlite3.reset(stmt),
               :ok <- Sqlite3.bind(stmt, [text, source_uri, idx]),
               :done <- Sqlite3.step(db, stmt) do
            {:cont, {:ok, n + 1}}
          else
            {:error, _} = err -> {:halt, err}
            other -> {:halt, {:error, {:insert_failed, other}}}
          end
        end)

      _ = Sqlite3.release(db, stmt)
      result
    end
  end

  defp row_to_hit([rowid, text, source_uri, score]) do
    %{
      chunk_id: rowid,
      text: text,
      source_uri: source_uri,
      # bm25 returns a negative number (more negative = better); negate so a
      # larger score = a better hit, matching the §5.4 "score" intent.
      score: -1.0 * score * 1.0
    }
  end

  # Normalize a free-text query into a safe FTS5 MATCH operand: split on
  # non-alphanumeric (across scripts), wrap each surviving token as a quoted
  # FTS5 string so metacharacters are literal, OR the tokens together. Tokens
  # shorter than 3 chars cannot match the trigram index and are dropped to
  # avoid a `MATCH` that errors or returns nothing surprising.
  defp normalize_match(query_string) do
    query_string
    |> String.split(~r/[^[:alnum:]]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3))
    |> Enum.map(&fts5_quote/1)
    |> Enum.join(" OR ")
  end

  # Wrap a token as a quoted FTS5 string literal — double any embedded quote
  # (FTS5's own escaping for a `"`-delimited string), so the token is matched
  # as literal text regardless of metacharacters.
  defp fts5_quote(token) do
    ~s("#{String.replace(token, "\"", "\"\"")}")
  end
end
