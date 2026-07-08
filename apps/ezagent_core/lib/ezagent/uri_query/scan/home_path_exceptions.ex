defmodule Ezagent.UriQuery.Scan.HomePathExceptions do
  @moduledoc """
  Exact `Module.function/arity` + line anchors for sanctioned raw
  `Ezagent.Home.path/1` / `Ezagent.Home.profile_dir/0` / `Ezagent.Home.home/0`
  callers (Resource-unification SPEC §5.2, Decisions D1/D2).

  These are the *permanent* sanctioned surface: config-eval (`UriQuery` ETS is
  absent before the supervision tree starts), early-boot helpers, operator
  mix-tasks (run app-not-started), and OS-handle artifacts that are not
  URI-addressable (the codex SUN_LEN short-path socket). They never migrate —
  unlike the burn-down `HomePathBaseline`.

  **NO globs, NO directory prefixes.** A directory-shaped exemption (e.g. "all of
  `lib/mix/tasks/`") would let a NEW `Home.path` call added under a globbed file
  evade the hard-fail-new gate (codex round-2 HIGH). Every entry is therefore a
  concrete `Module.function/arity` + line + stated reason. The scanner test (S-2)
  rejects any entry containing a `*` or a bare path prefix.

  Each entry: `{relative_path, "Module.function/arity", line, reason}`.

  Config files (`config/*.exs`) live OUTSIDE the scanner's `apps/**/*.ex` globs,
  so the scanner never sees them. They are listed here for completeness of the
  sanctioned surface (SPEC §5.2 note) and carry a `config/...:tag` function id;
  the malformed-entry guard tolerates that tag form and the anchor cross-check
  (S-2 codex MEDIUM) skips them (it only verifies `apps/**/*.ex` anchors).
  """

  # config-eval callers — outside apps/**/*.ex (scanner does not see them);
  # listed for completeness of the sanctioned surface (SPEC §5.2 note).
  @config_exceptions [
    {"config/runtime.exs", "config/runtime.exs:db", 14,
     "db path at config-eval — UriQuery ETS absent (D1)"},
    {"config/runtime.exs", "config/runtime.exs:db", 17, "db path at config-eval (D1)"}
  ]

  # runtime app code under apps/ — these ARE scanned; exact anchors (D2).
  @app_exceptions [
    # the resource:// resolver backend — R-4, the sanctioned SINGLE Home.path
    # chokepoint every migrated family routes through (SPEC §5.1). Not migratable
    # (it IS the migration target); not boot/operator.
    {"apps/ezagent_core/lib/ezagent/resource/fs_resolver.ex",
     "Ezagent.Resource.FsResolver.resolve/2", 153,
     "resource:// resolver backend — R-4 sanctioned single Home.path chokepoint"},
    # the system:// resolver backend (Resource-unification P3, SPEC §10 OI-3) —
    # the sanctioned SINGLE Home.path chokepoint every node-global system artifact
    # routes through. Not migratable (it IS the migration target); not boot/operator.
    # (line re-anchored 118→122: sw-home lane added the `socialware` catalog
    # entry + its moduledoc bullet above it)
    {"apps/ezagent_core/lib/ezagent/system/fs_resolver.ex", "Ezagent.System.FsResolver.resolve/1",
     122, "system:// resolver backend — R-4 sanctioned single Home.path chokepoint (P3)"},
    # early boot, pre-supervision (cookie file read before the registry exists)
    {"apps/ezagent_core/lib/ezagent/runtime.ex", "Ezagent.Runtime.cookie_path/0", 29,
     "early boot, pre-supervision (D2)"},
    # OS pid-file handle ("pty-pids"), registry-independent (D2)
    {"apps/ezagent_core/lib/ezagent/runtime/pid_file.ex", "Ezagent.Runtime.PidFile.dir/1", 113,
     "OS pid-file handle, registry-independent (D2)"},
    # operator mix-task: ezagent.home.init (app-not-started)
    {"apps/ezagent_core/lib/mix/tasks/ezagent.home.init.ex", "Mix.Tasks.Ezagent.Home.Init.run/1",
     30, "operator mix-task, app-not-started"},
    {"apps/ezagent_core/lib/mix/tasks/ezagent.home.init.ex", "Mix.Tasks.Ezagent.Home.Init.run/1",
     32, "operator mix-task, app-not-started"},
    {"apps/ezagent_core/lib/mix/tasks/ezagent.home.init.ex", "Mix.Tasks.Ezagent.Home.Init.run/1",
     33, "operator mix-task, app-not-started"},
    {"apps/ezagent_core/lib/mix/tasks/ezagent.home.init.ex", "Mix.Tasks.Ezagent.Home.Init.run/1",
     36, "operator mix-task, app-not-started"},
    {"apps/ezagent_core/lib/mix/tasks/ezagent.home.init.ex",
     "Mix.Tasks.Ezagent.Home.Init.ensure_credential_template/2", 55,
     "operator mix-task helper, app-not-started"},
    {"apps/ezagent_core/lib/mix/tasks/ezagent.home.init.ex",
     "Mix.Tasks.Ezagent.Home.Init.ensure_credentials_readme/0", 85,
     "operator mix-task helper, app-not-started"},
    {"apps/ezagent_core/lib/mix/tasks/ezagent.home.init.ex",
     "Mix.Tasks.Ezagent.Home.Init.print_summary/0", 151,
     "operator mix-task helper, app-not-started"},
    {"apps/ezagent_core/lib/mix/tasks/ezagent.home.init.ex",
     "Mix.Tasks.Ezagent.Home.Init.print_summary/0", 165,
     "operator mix-task helper, app-not-started"},
    # operator mix-task: ezagent.home.backup
    {"apps/ezagent_core/lib/mix/tasks/ezagent.home.backup.ex",
     "Mix.Tasks.Ezagent.Home.Backup.run/1", 60, "operator mix-task, app-not-started"},
    # operator mix-task: ezagent.bootstrap
    {"apps/ezagent_core/lib/mix/tasks/ezagent.bootstrap.ex", "Mix.Tasks.Ezagent.Bootstrap.run/1",
     88, "operator mix-task, app-not-started"},
    {"apps/ezagent_core/lib/mix/tasks/ezagent.bootstrap.ex", "Mix.Tasks.Ezagent.Bootstrap.run/1",
     89, "operator mix-task, app-not-started"},
    {"apps/ezagent_core/lib/mix/tasks/ezagent.bootstrap.ex", "Mix.Tasks.Ezagent.Bootstrap.run/1",
     90, "operator mix-task, app-not-started"},
    {"apps/ezagent_core/lib/mix/tasks/ezagent.bootstrap.ex", "Mix.Tasks.Ezagent.Bootstrap.run/1",
     91, "operator mix-task, app-not-started"},
    # operator migration tooling
    {"apps/ezagent_core/lib/ezagent/home/migration.ex", "Ezagent.Home.Migration.backup/1", 79,
     "operator migration tooling, app-not-started (D2)"},
    {"apps/ezagent_core/lib/ezagent/home/migration.ex", "Ezagent.Home.Migration.write_manifest/2",
     154, "operator migration tooling, app-not-started (D2)"},
    # OS-handle socket, SUN_LEN short-path, not URI-addressable (D2)
    # (line re-anchored 673→680: #1201 A② `host_login_dir/0` inserted above it)
    {"apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex",
     "Ezagent.PluginCodex.Template.CodexAgent.default_app_server_socket_path/1", 680,
     "OS-handle socket, SUN_LEN short-path, not URI-addressable (D2)"},
    # operator mix-task: ezagent.plugin.install — supplies EZAGENT_HOME/plugins
    # as the zip-unpack target for a plugin-package hot-load. The runtime
    # Ezagent.PluginPackage module is home-path-free (it takes :unpack_to as an
    # opt); this operator entry point is the sanctioned home-path resolver.
    {"apps/ezagent_core/lib/mix/tasks/ezagent.plugin.install.ex",
     "Mix.Tasks.Ezagent.Plugin.Install.install_from_path/2", 123,
     "operator mix-task — supplies EZAGENT_HOME/plugins as zip-unpack target"},
    # world layout one-shot migration (plugin-resource SPEC §4.4, HIGH-8) —
    # operator mix-task run app-not-started; re-keys legacy world/layouts JSON
    # onto the world-layouts/<ws>/<name> resolver path then deletes the old tree.
    # Core-located (NOT the world plugin) so it is excluded from
    # raw_home_path_outside_core, preserving the 2→1 ratchet; mirrors the
    # Mix.Tasks.Ezagent.Home.* operator anchors.
    {"apps/ezagent_core/lib/mix/tasks/ezagent.world.migrate_layouts.ex",
     "Mix.Tasks.Ezagent.World.MigrateLayouts.run/1", 58, "operator migration, app-not-started"},
    {"apps/ezagent_core/lib/mix/tasks/ezagent.world.migrate_layouts.ex",
     "Mix.Tasks.Ezagent.World.MigrateLayouts.migrate_one/3", 89,
     "operator migration, app-not-started"}
  ]

  @exceptions @config_exceptions ++ @app_exceptions

  @typedoc "An exception anchor: `{path, \"Module.function/arity\", line, reason}`."
  @type t :: {String.t(), String.t(), pos_integer(), String.t()}

  @doc "All sanctioned exception anchors (config + apps)."
  @spec all() :: [t()]
  def all, do: @exceptions

  @doc """
  Only the `apps/**/*.ex` exception anchors the scanner can actually see and
  cross-check against the live AST (S-2 codex MEDIUM). Config-tag entries are
  excluded because the scanner globs do not cover `config/`.
  """
  @spec app_anchors() :: [t()]
  def app_anchors do
    Enum.filter(@exceptions, fn {path, _fun_id, _line, _reason} ->
      String.starts_with?(path, "apps/") and String.ends_with?(path, ".ex")
    end)
  end

  @fun_id_re ~r/^[A-Z][\w.]*\.[a-z_][\w?!]*\/\d+$/

  @doc """
  S-2 guard: return the list of MALFORMED exception entries (empty = all valid).

  Each entry must be a concrete existing `.ex` file (or a `config/...` tag), a
  positive line, and a strict `Module.function/arity` id (regex
  `#{inspect(@fun_id_re)}`) — NO `*`, NO directory/path prefix. The strict
  function-id requirement does not apply to config tags (the scanner does not
  resolve those to AST).
  """
  @spec malformed_entries() :: [t()]
  def malformed_entries do
    Enum.reject(@exceptions, &valid_entry?/1)
  end

  @doc "True if any exception entry contains a glob or bare path prefix (S-2)."
  @spec any_glob_or_prefix?() :: boolean()
  def any_glob_or_prefix?, do: malformed_entries() != []

  defp valid_entry?({path, fun_id, line, _reason}) do
    config_tag? = String.starts_with?(path, "config/")

    valid_path =
      (config_tag? or String.ends_with?(path, ".ex")) and not String.contains?(path, "*")

    valid_fun =
      config_tag? or
        (Regex.match?(@fun_id_re, fun_id) and not String.contains?(fun_id, "*"))

    valid_line = is_integer(line) and line > 0

    valid_path and valid_fun and valid_line
  end
end
