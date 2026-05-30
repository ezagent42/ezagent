defmodule Ezagent.Home.Migration do
  @moduledoc """
  Full-home backup + restore for `$EZAGENT_HOME/$EZAGENT_PROFILE/` — the
  complete-migration capability (home portability #120).

  A backup is a **consistent** snapshot of one profile home: the SQLite
  database (the source of truth — Kind snapshots, users, caps, sessions,
  routing rules all live here), plus the on-disk config trees the DB
  *references* (`cc-agents/`, `codex/`, `credentials/`, `snapshots/`,
  `plugins/`, `uploads/`, `inbox/`). Restoring it onto a different machine
  or a different path fully reconstitutes the system.

  ## SQLite-consistency model

  This task is **Category A** (CLI/GUI parity audit 2026-05-24 — FS ops
  that run *around* the runtime BEAM, like `ezagent.home.adopt_db`). It does
  NOT start the runtime. The chosen safety model is:

    * **`VACUUM INTO`** via the `sqlite3` CLI to produce the DB copy. This
      reads a single consistent transaction view and writes a brand-new,
      fully-checkpointed database file — correct even if a `-wal` exists,
      and never touches the live DB's files. (Falls back to a
      `wal_checkpoint(TRUNCATE)` + raw copy only if `sqlite3` is absent.)
    * Because `VACUUM INTO` takes a read transaction, a backup taken while
      the server is *running* is still internally consistent. For a
      guaranteed-quiescent backup, stop the server first — documented, not
      enforced.

  ## Path portability

  Per `docs/notes/home-portability-audit.md`, the ONLY persisted absolute
  paths are the Sandbox slice's `config_dir_path` + the
  `agent_config_dir`/`claude_config_dir` embedded in
  `respawn_template_data`, all under `<profile_dir>/cc-agents/...`. They are
  buried inside `kind_snapshots.state_binary` (`term_to_binary`). On
  `restore`, after the tree is in place, every snapshot blob is decoded, any
  string whose prefix is the *source* `profile_dir` is rewritten to the
  *target* `profile_dir`, and re-encoded. The source `profile_dir` is
  recorded in the backup manifest so the rewrite needs no guessing.

  (The durable structural alternative — store profile-relative paths and
  resolve at read time — is deferred; see the audit doc + futures/todo.)
  """

  alias Ezagent.Home

  @manifest_name "MANIFEST.json"
  @db_basename "ezagent_core.db"

  # Subdirs included in a backup. db/ is handled specially (VACUUM INTO).
  # Excluded (ephemeral / host-local, rebuilt on boot): logs/, pty-pids/,
  # runtime/ (node cookie). See audit doc.
  @backup_subdirs ~w(cc-agents codex credentials snapshots plugins uploads inbox)
  @excluded_subdirs ~w(logs pty-pids runtime)

  @doc "Subdirs (besides db/) copied into a backup."
  def backup_subdirs, do: @backup_subdirs

  @doc "Subdirs deliberately omitted from a backup (ephemeral / host-local)."
  def excluded_subdirs, do: @excluded_subdirs

  # --------------------------------------------------------------------------
  # BACKUP
  # --------------------------------------------------------------------------

  @doc """
  Back up the **active** profile home (resolved from `EZAGENT_HOME` /
  `EZAGENT_PROFILE`) into `out_path`.

  `out_path` ending in `.tar.gz` (or `.tgz`) produces a gzipped tarball;
  any other path is treated as a directory to populate.

  Returns `{:ok, out_path}` or `{:error, reason}`.
  """
  @spec backup(String.t()) :: {:ok, String.t()} | {:error, term()}
  def backup(out_path) when is_binary(out_path) do
    src_profile_dir = Home.profile_dir()

    cond do
      not File.dir?(src_profile_dir) ->
        {:error, {:home_not_found, src_profile_dir}}

      true ->
        staging = staging_dir!("ezagent-backup")

        try do
          with :ok <- stage_db(src_profile_dir, staging),
               :ok <- stage_subdirs(src_profile_dir, staging),
               :ok <- write_manifest(staging, src_profile_dir),
               {:ok, _} <- emit(staging, out_path) do
            {:ok, out_path}
          end
        after
          File.rm_rf(staging)
        end
    end
  end

  # VACUUM INTO produces a consistent, checkpointed copy of the live DB.
  defp stage_db(src_profile_dir, staging) do
    src_db = Path.join([src_profile_dir, "db", @db_basename])

    if File.exists?(src_db) do
      File.mkdir_p!(Path.join(staging, "db"))
      dst_db = Path.join([staging, "db", @db_basename])
      consistent_db_copy(src_db, dst_db)
    else
      # No DB yet (fresh home) — nothing to copy; restore will start empty.
      :ok
    end
  end

  @doc false
  # Public-ish for testing the consistency primitive in isolation.
  def consistent_db_copy(src_db, dst_db) do
    case System.find_executable("sqlite3") do
      nil ->
        # Fallback: checkpoint the WAL into the main file via the NIF, then
        # raw-copy the (now self-contained) DB file.
        checkpoint_then_copy(src_db, dst_db)

      sqlite3 ->
        # VACUUM INTO writes a fresh, fully-checkpointed DB; reads a single
        # consistent snapshot of `src_db`. dst must NOT pre-exist.
        File.rm(dst_db)

        case System.cmd(sqlite3, [src_db, "VACUUM INTO '#{dst_db}'"],
               stderr_to_stdout: true
             ) do
          {_out, 0} -> :ok
          {out, code} -> {:error, {:vacuum_into_failed, code, String.trim(out)}}
        end
    end
  end

  defp checkpoint_then_copy(src_db, dst_db) do
    case Exqlite.Sqlite3.open(src_db, mode: :readwrite) do
      {:ok, conn} ->
        _ = Exqlite.Sqlite3.execute(conn, "PRAGMA wal_checkpoint(TRUNCATE);")
        :ok = Exqlite.Sqlite3.close(conn)
        File.cp!(src_db, dst_db)
        :ok

      {:error, reason} ->
        {:error, {:db_open_failed, reason}}
    end
  end

  defp stage_subdirs(src_profile_dir, staging) do
    Enum.each(@backup_subdirs, fn sub ->
      src = Path.join(src_profile_dir, sub)

      if File.dir?(src) do
        dst = Path.join(staging, sub)
        File.mkdir_p!(Path.dirname(dst))
        File.cp_r!(src, dst)
      end
    end)

    :ok
  end

  defp write_manifest(staging, src_profile_dir) do
    manifest = %{
      "version" => 1,
      "tool" => "ezagent.home.backup",
      "task" => "home portability (#120)",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      # The absolute source profile_dir — the prefix `restore` rewrites
      # persisted absolute paths AWAY from.
      "source_profile_dir" => src_profile_dir,
      "source_home" => Home.home(),
      "source_profile" => Home.profile(),
      "included_subdirs" => @backup_subdirs,
      "excluded_subdirs" => @excluded_subdirs,
      "db_basename" => @db_basename
    }

    File.write(Path.join(staging, @manifest_name), Jason.encode!(manifest, pretty: true))
  end

  # Either tar+gzip the staging dir, or copy it to a plain output directory.
  defp emit(staging, out_path) do
    if tarball?(out_path) do
      File.mkdir_p!(Path.dirname(Path.expand(out_path)))
      tar_gz(staging, out_path)
    else
      out = Path.expand(out_path)

      if File.exists?(out) and not empty_dir?(out) do
        {:error, {:output_exists, out}}
      else
        File.mkdir_p!(out)
        File.cp_r!(staging, out)
        {:ok, out}
      end
    end
  end

  defp tar_gz(staging, out_path) do
    out = Path.expand(out_path)
    # Build a list of {arcname, abspath} so the archive has no leading
    # staging-tmp prefix — entries are `db/...`, `cc-agents/...`, MANIFEST.json.
    entries =
      staging
      |> File.ls!()
      |> Enum.map(fn name ->
        {String.to_charlist(name), String.to_charlist(Path.join(staging, name))}
      end)

    case :erl_tar.create(String.to_charlist(out), entries, [:compressed]) do
      :ok -> {:ok, out}
      {:error, reason} -> {:error, {:tar_create_failed, reason}}
    end
  end

  # --------------------------------------------------------------------------
  # RESTORE
  # --------------------------------------------------------------------------

  @doc """
  Restore a backup at `from_path` into the target home `target_home`
  (an `EZAGENT_HOME` value) under profile `target_profile`.

  `from_path` may be a `.tar.gz`/`.tgz` produced by `backup/1`, or a
  directory populated by `backup/1`.

  Rewrites every persisted absolute path under the *source* profile_dir to
  the *target* profile_dir (see moduledoc). Refuses to clobber a non-empty
  target profile dir unless `force: true`.

  Options: `force: boolean` (default false).

  Returns `{:ok, target_profile_dir}` or `{:error, reason}`.
  """
  @spec restore(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def restore(from_path, target_home, target_profile, opts \\ [])
      when is_binary(from_path) and is_binary(target_home) and is_binary(target_profile) do
    force? = Keyword.get(opts, :force, false)
    target_home = Path.expand(target_home)
    target_profile_dir = Path.join(target_home, target_profile)

    with {:ok, src_root} <- materialize(from_path),
         {:ok, manifest} <- read_manifest(src_root),
         :ok <- guard_target(target_profile_dir, force?) do
      try do
        File.mkdir_p!(target_profile_dir)
        set_perms(target_profile_dir, 0o700)
        copy_tree(src_root, target_profile_dir)
        ensure_runtime_skeleton(target_profile_dir)

        case rewrite_paths(target_profile_dir, manifest["source_profile_dir"]) do
          {:ok, n} -> {:ok, {target_profile_dir, n}}
          {:error, _} = err -> err
        end
      after
        if tarball?(from_path), do: File.rm_rf(src_root)
      end
    end
  end

  # If from_path is a tarball, unpack into a temp dir and return it; if a
  # directory, return it directly.
  defp materialize(from_path) do
    cond do
      tarball?(from_path) and File.regular?(from_path) ->
        dest = staging_dir!("ezagent-restore")

        case :erl_tar.extract(String.to_charlist(Path.expand(from_path)),
               [:compressed, {:cwd, String.to_charlist(dest)}]
             ) do
          :ok -> {:ok, dest}
          {:error, reason} -> {:error, {:tar_extract_failed, reason}}
        end

      File.dir?(from_path) ->
        {:ok, Path.expand(from_path)}

      true ->
        {:error, {:backup_not_found, from_path}}
    end
  end

  defp read_manifest(src_root) do
    file = Path.join(src_root, @manifest_name)

    case File.read(file) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"source_profile_dir" => spd} = m} when is_binary(spd) -> {:ok, m}
          {:ok, _} -> {:error, :manifest_missing_source_profile_dir}
          {:error, reason} -> {:error, {:manifest_decode_failed, reason}}
        end

      {:error, _} ->
        {:error, {:manifest_not_found, file}}
    end
  end

  defp guard_target(target_profile_dir, force?) do
    cond do
      not File.exists?(target_profile_dir) -> :ok
      empty_dir?(target_profile_dir) -> :ok
      force? -> :ok
      true -> {:error, {:target_not_empty, target_profile_dir}}
    end
  end

  # Copy everything except the manifest into the target profile dir.
  defp copy_tree(src_root, target_profile_dir) do
    src_root
    |> File.ls!()
    |> Enum.reject(&(&1 == @manifest_name))
    |> Enum.each(fn name ->
      src = Path.join(src_root, name)
      dst = Path.join(target_profile_dir, name)
      File.rm_rf(dst)
      File.cp_r!(src, dst)
    end)

    creds = Path.join(target_profile_dir, "credentials")
    if File.dir?(creds), do: set_perms(creds, 0o700)
  end

  # Recreate the ephemeral subdirs we excluded so the restored home is a
  # complete, bootable skeleton.
  defp ensure_runtime_skeleton(target_profile_dir) do
    Enum.each(@excluded_subdirs ++ ["db"], fn sub ->
      File.mkdir_p!(Path.join(target_profile_dir, sub))
    end)
  end

  # --------------------------------------------------------------------------
  # PATH REWRITE (the portability fix)
  # --------------------------------------------------------------------------

  @doc """
  Rewrite every persisted absolute path under `source_profile_dir` inside
  the restored DB's `kind_snapshots.state_binary` blobs to point at
  `target_profile_dir`. Returns `{:ok, rows_rewritten}`.

  Idempotent: a path already under the target prefix is left untouched.
  """
  @spec rewrite_paths(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rewrite_paths(target_profile_dir, source_profile_dir)
      when is_binary(target_profile_dir) and is_binary(source_profile_dir) do
    db = Path.join([target_profile_dir, "db", @db_basename])

    cond do
      not File.exists?(db) ->
        # No DB in the backup (fresh home) — nothing to rewrite.
        {:ok, 0}

      source_profile_dir == target_profile_dir ->
        # Same path (in-place restore) — no rewrite needed.
        {:ok, 0}

      true ->
        do_rewrite(db, source_profile_dir, target_profile_dir)
    end
  end

  @doc false
  # Test seam: rewrite a specific DB file's snapshot paths from `src_prefix`
  # to `dst_prefix` directly (the public `rewrite_paths/2` derives the DB
  # location from the *target* profile dir, which assumes an already-restored
  # tree). Used by the home-migration regression test.
  def rewrite_paths_for_test(db, src_prefix, dst_prefix)
      when is_binary(db) and is_binary(src_prefix) and is_binary(dst_prefix) do
    do_rewrite(db, src_prefix, dst_prefix)
  end

  defp do_rewrite(db, src_prefix, dst_prefix) do
    case Exqlite.Sqlite3.open(db, mode: :readwrite) do
      {:ok, conn} ->
        try do
          rows = select_snapshots(conn)

          rewritten =
            Enum.reduce(rows, 0, fn {uri, bin}, acc ->
              case maybe_rewrite_blob(bin, src_prefix, dst_prefix) do
                :unchanged -> acc
                {:changed, new_bin} -> update_snapshot(conn, uri, new_bin) + acc
              end
            end)

          {:ok, rewritten}
        after
          Exqlite.Sqlite3.close(conn)
        end

      {:error, reason} ->
        {:error, {:db_open_failed, reason}}
    end
  end

  defp select_snapshots(conn) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(
        conn,
        "SELECT uri, state_binary FROM kind_snapshots WHERE state_binary IS NOT NULL"
      )

    {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
    Enum.map(rows, fn [uri, bin] -> {uri, bin} end)
  end

  defp update_snapshot(conn, uri, new_bin) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(conn, "UPDATE kind_snapshots SET state_binary = ?1 WHERE uri = ?2")

    :ok = Exqlite.Sqlite3.bind_blob(stmt, 1, new_bin)
    :ok = Exqlite.Sqlite3.bind_text(stmt, 2, uri)
    :done = Exqlite.Sqlite3.step(conn, stmt)
    1
  end

  # Decode the snapshot term, deep-rewrite any string with the src prefix,
  # re-encode. Returns `:unchanged` or `{:changed, binary}`.
  #
  # NOTE: decode is WITHOUT the `:safe` flag. The restore task starts only
  # `:exqlite`, not the full runtime, so plugin atoms carried in the slice
  # (e.g. `EzagentPluginCc.Template.CcAgent` in `template_class`) are NOT
  # loaded — `binary_to_term(_, [:safe])` would REJECT the whole blob and we
  # would silently skip a row that needs rewriting (the original bug). The
  # backup is operator-owned, trusted data we ourselves produced; round-
  # tripping it through `term_to_binary` is the explicit intent.
  defp maybe_rewrite_blob(bin, src_prefix, dst_prefix) when is_binary(bin) do
    try do
      term = :erlang.binary_to_term(bin)
      {new_term, changed?} = deep_rewrite(term, src_prefix, dst_prefix)

      if changed? do
        {:changed, :erlang.term_to_binary(new_term)}
      else
        :unchanged
      end
    rescue
      # A genuinely-corrupt blob is left exactly as-is rather than risking
      # corruption (vanishingly unlikely for a backup we just wrote).
      _ -> :unchanged
    end
  end

  # Deep-walk arbitrary terms, rewriting the absolute-path prefix in any
  # binary string. Returns `{term, changed?}`.
  defp deep_rewrite(s, src, dst) when is_binary(s) do
    if String.starts_with?(s, src) do
      {dst <> binary_part(s, byte_size(src), byte_size(s) - byte_size(src)), true}
    else
      {s, false}
    end
  end

  defp deep_rewrite(list, src, dst) when is_list(list) do
    {rev, changed?} =
      Enum.reduce(list, {[], false}, fn el, {acc, ch} ->
        {new_el, c} = deep_rewrite(el, src, dst)
        {[new_el | acc], ch or c}
      end)

    {Enum.reverse(rev), changed?}
  end

  defp deep_rewrite(%MapSet{} = ms, src, dst) do
    {list, changed?} = deep_rewrite(MapSet.to_list(ms), src, dst)
    {MapSet.new(list), changed?}
  end

  defp deep_rewrite(%{__struct__: mod} = struct, src, dst) do
    {plain, changed?} = deep_rewrite(Map.from_struct(struct), src, dst)
    {struct(mod, plain), changed?}
  end

  defp deep_rewrite(map, src, dst) when is_map(map) do
    {kvs, changed?} =
      Enum.reduce(map, {[], false}, fn {k, v}, {acc, ch} ->
        {new_k, ck} = deep_rewrite(k, src, dst)
        {new_v, cv} = deep_rewrite(v, src, dst)
        {[{new_k, new_v} | acc], ch or ck or cv}
      end)

    {Map.new(kvs), changed?}
  end

  defp deep_rewrite(tuple, src, dst) when is_tuple(tuple) do
    {list, changed?} = deep_rewrite(Tuple.to_list(tuple), src, dst)
    {List.to_tuple(list), changed?}
  end

  defp deep_rewrite(other, _src, _dst), do: {other, false}

  # --------------------------------------------------------------------------
  # helpers
  # --------------------------------------------------------------------------

  defp tarball?(path) when is_binary(path),
    do: String.ends_with?(path, ".tar.gz") or String.ends_with?(path, ".tgz")

  defp empty_dir?(path), do: File.dir?(path) and File.ls!(path) == []

  defp staging_dir!(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp set_perms(path, mode) do
    case :os.type() do
      {:unix, _} -> File.chmod(path, mode)
      _ -> :ok
    end
  end
end
