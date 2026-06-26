defmodule EzagentPluginKb.StoreTest do
  @moduledoc """
  Pure store tests — exqlite FTS5 (trigram), no framework. These are the
  hardest load-bearing proofs decoupled from the agent path:

  * round-trip (SPEC §8.1 store half) — ingest then query returns the chunk
  * **PORTABILITY (SPEC §8.9, the headline constraint)** — export the file,
    open the COPY as a second standalone handle, corpus + index intact +
    queryable WITHOUT the original handle
  * re-ingest = replace (SPEC §8.4b)
  * SQL safety (SPEC §8.4d) — FTS5/SQL metacharacters are DATA, never error
  * bilingual (trigram) — Chinese is searchable (the tokenizer decision §9.4)
  """
  use ExUnit.Case, async: true

  alias EzagentPluginKb.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "kb-store-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, path: Path.join(dir, "kb.sqlite")}
  end

  defp open!(path) do
    {:ok, db} = Store.open(path)
    on_exit(fn -> Store.close(db) end)
    db
  end

  describe "round-trip (SPEC §8.1 store half)" do
    test "ingest then query returns the matching chunk with provenance", %{path: path} do
      db = open!(path)

      assert {:ok, 2} =
               Store.ingest(db, "resource://ws/kb-source/doc1", [
                 {0, "the quick brown fox jumps over the lazy dog"},
                 {1, "elixir processes are lightweight and isolated"}
               ])

      assert {:ok, hits} = Store.query(db, "elixir processes", 5)
      assert [%{text: text, source_uri: src, chunk_id: id, score: score} | _] = hits
      assert text =~ "elixir"
      assert src == "resource://ws/kb-source/doc1"
      assert is_integer(id)
      assert is_float(score)
    end

    test "query respects k (top-k limit)", %{path: path} do
      db = open!(path)

      chunks = for i <- 0..9, do: {i, "alpha beta gamma chunk number #{i}"}
      assert {:ok, 10} = Store.ingest(db, "resource://ws/kb-source/many", chunks)

      assert {:ok, hits} = Store.query(db, "alpha beta", 3)
      assert length(hits) == 3
    end
  end

  describe "PORTABILITY (SPEC §8.9 — the headline constraint)" do
    test "export the file, open the COPY standalone, corpus intact + queryable",
         %{dir: dir, path: path} do
      db = open!(path)

      assert {:ok, 1} =
               Store.ingest(db, "resource://ws/kb-source/portable", [
                 {0, "knowledge bases must be portable independent artifacts"}
               ])

      # Export = the portability operation. The copy is self-contained.
      copy = Path.join(dir, "exported-kb.sqlite")
      assert :ok = Store.export(db, copy)
      assert File.exists?(copy)

      # Open the COPY as a SEPARATE handle (a second "process"/tool) — no
      # dependency on the original handle. This proves the corpus + FTS5 index
      # travelled with the file.
      {:ok, copy_db} = Store.open(copy)
      on_exit(fn -> Store.close(copy_db) end)

      assert {:ok, [%{text: text, source_uri: src} | _]} =
               Store.query(copy_db, "portable independent", 5)

      assert text =~ "portable"
      assert src == "resource://ws/kb-source/portable"
    end

    test "the exported copy is a single self-contained file (no WAL sidecar needed)",
         %{dir: dir, path: path} do
      db = open!(path)
      assert {:ok, 1} = Store.ingest(db, "resource://ws/kb-source/x", [{0, "single file corpus"}])

      copy = Path.join(dir, "single.sqlite")
      assert :ok = Store.export(db, copy)

      # No `-wal`/`-shm` sidecars are required to read the copy (DELETE
      # journaling): opening JUST the copied file yields the corpus.
      {:ok, copy_db} = Store.open(copy)
      on_exit(fn -> Store.close(copy_db) end)
      assert {:ok, [_ | _]} = Store.query(copy_db, "single file", 5)
    end
  end

  describe "re-ingest = replace (SPEC §8.4b)" do
    test "ingesting the same source twice yields one copy of each chunk", %{path: path} do
      db = open!(path)
      src = "resource://ws/kb-source/dedupe"

      assert {:ok, 1} = Store.ingest(db, src, [{0, "first version of the document content"}])
      assert {:ok, 1} = Store.ingest(db, src, [{0, "second version of the document content"}])

      assert {:ok, hits} = Store.query(db, "version document", 50)
      assert length(hits) == 1
      assert [%{text: text}] = hits
      assert text =~ "second version"
    end

    test "re-ingesting one source leaves OTHER sources intact", %{path: path} do
      db = open!(path)

      assert {:ok, 1} =
               Store.ingest(db, "resource://ws/kb-source/a", [{0, "apple banana cherry"}])

      assert {:ok, 1} = Store.ingest(db, "resource://ws/kb-source/b", [{0, "delta echo foxtrot"}])
      # re-ingest a, b must survive
      assert {:ok, 1} = Store.ingest(db, "resource://ws/kb-source/a", [{0, "apricot blueberry"}])

      assert {:ok, [_]} = Store.query(db, "delta echo", 50)
    end
  end

  describe "SQL safety (SPEC §8.4d)" do
    test "FTS5/SQL metacharacters are treated as DATA — no error, no injection", %{path: path} do
      db = open!(path)

      assert {:ok, 1} =
               Store.ingest(db, "resource://ws/kb-source/s", [{0, "harmless corpus text"}])

      for evil <- [
            # bare quote — would break a naive MATCH string
            ~s("),
            "*",
            "AND 1=1",
            "'; DROP TABLE chunks; --",
            "NEAR(foo bar)",
            "harmless\" OR \"x"
          ] do
        # Must NOT raise and must NOT error — returns a list (possibly empty).
        assert {:ok, hits} = Store.query(db, evil, 5)
        assert is_list(hits)
      end

      # The corpus survived every "injection" attempt.
      assert {:ok, [_ | _]} = Store.query(db, "harmless corpus", 5)
    end
  end

  describe "bilingual / trigram (SPEC §9.4 tokenizer decision)" do
    test "Chinese content is searchable with the trigram tokenizer", %{path: path} do
      db = open!(path)

      assert {:ok, 1} =
               Store.ingest(db, "resource://ws/kb-source/zh", [
                 {0, "知识库必须是可移植的独立数据文件"}
               ])

      assert {:ok, [%{text: text} | _]} = Store.query(db, "知识库", 5)
      assert text =~ "知识库"
    end
  end
end
