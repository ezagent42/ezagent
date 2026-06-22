defmodule Ezagent.Home.Migration do
  @moduledoc """
  Full-home backup + restore for `$EZAGENT_HOME/$EZAGENT_PROFILE/` — the
  complete-migration capability (home portability #120).

  A backup is a **consistent** snapshot of one profile home: the PostgreSQL
  database (the source of truth — Kind snapshots, users, caps, sessions,
  routing rules all live here), plus the on-disk config trees the DB
  *references* (`cc-agents/`, `codex/`, `credentials/`, `snapshots/`,
  `plugins/`, `uploads/`, `inbox/`). Restoring it onto a different machine
  or a different path fully reconstitutes the system.

  ## PostgreSQL consistency model

  This task is **Category A** (CLI/GUI parity audit 2026-05-24 — FS ops
  that run *around* the runtime BEAM, like `ezagent.home.adopt_db`). It does
  NOT start the runtime. The chosen safety model is:

    * **`pg_dump --format=custom`** produces a transactionally-consistent
      dump of the configured Repo database without touching live table files.
    * **`pg_restore --clean --if-exists`** restores that dump into the
      currently configured Repo database. The target DB is intentionally
      controlled by Repo config / `DATABASE_URL`, not by `$EZAGENT_HOME`.

  ## Path portability

  Per `docs/notes/home-portability-audit.md`, the ONLY persisted absolute
  paths are the Sandbox slice's `config_dir_path` + the
  `agent_config_dir`/`config_dir` embedded in
  `respawn_template_data` (config_dir promotion, Allen 2026-06-03: the
  per-agent config-home is the universal, flavor-neutral `config_dir` key —
  was `claude_config_dir`), all under `<profile_dir>/cc-agents/...`. They are
  buried inside `kind_snapshots.state_binary` (`term_to_binary`). On
  `restore`, after the tree is in place, every snapshot blob is decoded, any
  string whose prefix is the *source* `profile_dir` is rewritten to the
  *target* `profile_dir`, and re-encoded. The source `profile_dir` is
  recorded in the backup manifest so the rewrite needs no guessing.

  (The durable structural alternative — store profile-relative paths and
  resolve at read time — is deferred; see the audit doc + futures/todo.)
  """

  alias Ezagent.Home
  alias Ezagent.Ecto.KindSnapshot
  alias EzagentCore.Repo

  import Ecto.Query

  @manifest_name "MANIFEST.json"
  @db_dump_basename "ezagent_core.dump"

  # Subdirs included in a backup. db/ is handled specially (pg_dump).
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

  defp stage_db(src_profile_dir, staging) do
    _ = src_profile_dir
    File.mkdir_p!(Path.join(staging, "db"))
    dump = Path.join([staging, "db", @db_dump_basename])
    pg_dump(dump)
  end

  @doc false
  # Public-ish for testing the consistency primitive in isolation.
  def pg_dump(dst_dump) when is_binary(dst_dump) do
    with {:ok, pg_dump} <- find_pg_tool("pg_dump"),
         {:ok, url} <- repo_database_url() do
      File.rm(dst_dump)

      args = [
        "--format=custom",
        "--no-owner",
        "--no-acl",
        "--file",
        dst_dump,
        url
      ]

      case System.cmd(pg_dump, args, stderr_to_stdout: true) do
        {_out, 0} -> :ok
        {out, code} -> {:error, {:pg_dump_failed, code, String.trim(out)}}
      end
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
      "db_dump_basename" => @db_dump_basename,
      "database" => repo_database_metadata()
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

        case restore_db(src_root) do
          :ok -> :ok
          {:error, _} = err -> throw(err)
        end

        case rewrite_paths(target_profile_dir, manifest["source_profile_dir"]) do
          {:ok, n} -> {:ok, {target_profile_dir, n}}
          {:error, _} = err -> err
        end
      catch
        {:error, _} = err -> err
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

        case :erl_tar.extract(
               String.to_charlist(Path.expand(from_path)),
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

  # Copy everything except the manifest and database dump into the target profile dir.
  defp copy_tree(src_root, target_profile_dir) do
    src_root
    |> File.ls!()
    |> Enum.reject(&(&1 in [@manifest_name, "db"]))
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
  the configured Repo's `kind_snapshots.state_binary` blobs to point at
  `target_profile_dir`. Returns `{:ok, rows_rewritten}`.

  Idempotent: a path already under the target prefix is left untouched.
  """
  @spec rewrite_paths(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rewrite_paths(target_profile_dir, source_profile_dir)
      when is_binary(target_profile_dir) and is_binary(source_profile_dir) do
    cond do
      source_profile_dir == target_profile_dir ->
        # Same path (in-place restore) — no rewrite needed.
        {:ok, 0}

      true ->
        do_rewrite(source_profile_dir, target_profile_dir)
    end
  end

  @doc false
  # Test seam retained for existing focused tests; PostgreSQL rewrite always
  # uses the currently configured Repo, so the first argument is ignored.
  def rewrite_paths_for_test(_db, src_prefix, dst_prefix)
      when is_binary(src_prefix) and is_binary(dst_prefix) do
    do_rewrite(src_prefix, dst_prefix)
  end

  defp do_rewrite(src_prefix, dst_prefix) do
    with_repo(fn ->
      rows = select_snapshots()

      rewritten =
        Enum.reduce(rows, 0, fn {uri, bin}, acc ->
          case maybe_rewrite_blob(bin, src_prefix, dst_prefix) do
            :unchanged -> acc
            {:changed, new_bin} -> update_snapshot(uri, new_bin) + acc
          end
        end)

      {:ok, rewritten}
    end)
  end

  defp select_snapshots do
    from(s in KindSnapshot,
      where: not is_nil(s.state_binary),
      select: {s.uri, s.state_binary}
    )
    |> Repo.all()
  end

  defp update_snapshot(uri, new_bin) do
    {count, _} =
      from(s in KindSnapshot, where: s.uri == ^uri)
      |> Repo.update_all(set: [state_binary: new_bin])

    count
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

  defp restore_db(src_root) do
    dump = Path.join([src_root, "db", @db_dump_basename])

    if File.regular?(dump) do
      pg_restore(dump)
    else
      :ok
    end
  end

  @doc false
  def pg_restore(src_dump) when is_binary(src_dump) do
    with {:ok, pg_restore} <- find_pg_tool("pg_restore"),
         {:ok, url} <- repo_database_url() do
      args = [
        "--clean",
        "--if-exists",
        "--no-owner",
        "--no-acl",
        "--dbname",
        url,
        src_dump
      ]

      case System.cmd(pg_restore, args, stderr_to_stdout: true) do
        {_out, 0} -> :ok
        {out, code} -> pg_restore_error(code, String.trim(out))
      end
    end
  end

  defp pg_restore_error(code, out) do
    if benign_transaction_timeout_restore_warning?(out) do
      :ok
    else
      {:error, {:pg_restore_failed, code, out}}
    end
  end

  defp benign_transaction_timeout_restore_warning?(out) do
    String.contains?(out, ~s(unrecognized configuration parameter "transaction_timeout")) and
      String.contains?(out, "SET transaction_timeout = 0") and
      String.contains?(out, "errors ignored on restore: 1")
  end

  defp find_pg_tool(name) do
    case System.find_executable(name) do
      nil -> {:error, {:missing_executable, name}}
      path -> {:ok, path}
    end
  end

  defp repo_database_url do
    config = Repo.config()

    cond do
      url = config[:url] ->
        {:ok, url}

      database = config[:database] ->
        username = to_string(config[:username] || "")
        password = config[:password]
        hostname = to_string(config[:hostname] || "localhost")
        port = config[:port] || 5432

        userinfo =
          case {username, password} do
            {"", _} -> ""
            {user, nil} -> URI.encode_www_form(user) <> "@"
            {user, pass} -> URI.encode_www_form(user) <> ":" <> URI.encode_www_form(pass) <> "@"
          end

        {:ok, "postgresql://#{userinfo}#{hostname}:#{port}/#{database}"}

      true ->
        {:error, :repo_database_not_configured}
    end
  end

  defp repo_database_metadata do
    config = Repo.config()

    %{
      "adapter" => "postgrex",
      "hostname" => to_string(config[:hostname] || ""),
      "port" => config[:port],
      "database" => config[:database],
      "username" => config[:username],
      "has_password" => not is_nil(config[:password]) and config[:password] != ""
    }
  end

  defp with_repo(fun) do
    case Process.whereis(Repo) do
      nil ->
        with :ok <- ensure_repo_dependencies_started() do
          {:ok, pid} = Repo.start_link()

          try do
            fun.()
          after
            GenServer.stop(pid)
          end
        end

      _pid ->
        fun.()
    end
  end

  defp ensure_repo_dependencies_started do
    with {:ok, _} <- Application.ensure_all_started(:ecto_sql),
         {:ok, _} <- Application.ensure_all_started(:postgrex) do
      :ok
    else
      {:error, reason} -> {:error, {:repo_dependency_start_failed, reason}}
    end
  end
end
