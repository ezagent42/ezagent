defmodule Mix.Tasks.Ezagent.World.MigrateLayouts do
  @shortdoc "One-shot: move legacy world layouts onto the resource:// seam layout"
  @moduledoc """
  > **Operator one-shot migration (plugin-resource SPEC §4.4, HIGH-8).** Run once
  > at deploy of the plugin-resource world adopter. Like `ezagent.home.*`, this is
  > intentionally NOT a dispatched op — it moves on-disk layout JSON around the
  > runtime BEFORE the app is started; stays as `mix ezagent.world.*`.

  Migrates the `world` plugin's layout store off the legacy
  `EZAGENT_HOME/world/layouts/<name>.json` tree onto the
  `resource://<ws>/world-layouts/<name>` seam's backing path
  (`EZAGENT_HOME/world-layouts/<ws>/<name>`), then deletes the old tree.

  ## Why an eager one-shot (not a lazy runtime fallback)

  The runtime `Ezagent.World.LayoutManager` resolves layouts PURELY through
  `Ezagent.Resource.FsResolver.resolve/2` — it has NO raw `Ezagent.Home.path/1`
  left, so `raw_home_path_outside_core` genuinely ratchets 2 → 1. Preserving
  existing operator-authored layouts therefore cannot be a runtime read of the
  old path; it is this one-shot eager re-key instead.

  This task's OWN `Ezagent.Home.path/1` reads/writes are the sanctioned
  **operator mix-task** class (run app-not-started; same as the
  `Mix.Tasks.Ezagent.Home.*` tasks), exact-anchored in
  `Ezagent.UriQuery.Scan.HomePathExceptions` with an "operator migration,
  app-not-started" reason. The task lives in `ezagent_core` (not the world
  plugin) because an outside-core `Home.path/1` caller is counted by
  `raw_home_path_outside_core` and would defeat the 2 → 1 ratchet; core-located
  operator tasks are excluded from that metric by construction (the same place
  every `Mix.Tasks.Ezagent.Home.*` task lives). It depends only on core modules
  (`Ezagent.Home`, `Ezagent.URI`, `Jason`) — no world-plugin dependency (core
  cannot depend on a plugin).

  ## `<name>` mapping

  The new resolver `<name>` IS the legacy filename STEM (both are
  `scope_uri |> Ezagent.URI.stable_key() |> Base.url_encode64(padding: false)`).
  So a legacy `world/layouts/<stem>.json` re-keys to `world-layouts/<ws>/<stem>`
  (no extension — the resolver's `<name>` segment carries no `.json`). `<ws>` is
  recovered from each file's `"scope"` JSON field (it stores
  `URI.to_string(scope_uri)`), parsed back to its workspace name.

  ## Usage

      mix ezagent.world.migrate_layouts            # migrate, then delete old tree
      mix ezagent.world.migrate_layouts --dry-run  # report only, no writes/deletes
  """
  use Mix.Task

  @legacy_component "world/layouts"
  @new_component "world-layouts"

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: [dry_run: :boolean])
    dry_run? = Keyword.get(opts, :dry_run, false)

    legacy_dir = Ezagent.Home.path(@legacy_component)

    case File.ls(legacy_dir) do
      {:error, :enoent} ->
        Mix.shell().info("No legacy world layout tree at #{legacy_dir} — nothing to migrate.")

      {:error, reason} ->
        Mix.raise("cannot list #{legacy_dir}: #{inspect(reason)}")

      {:ok, entries} ->
        json_files = Enum.filter(entries, &String.ends_with?(&1, ".json"))
        migrated = Enum.map(json_files, &migrate_one(legacy_dir, &1, dry_run?))
        ok_count = Enum.count(migrated, &(&1 == :ok))

        Mix.shell().info(
          "world layouts: #{ok_count}/#{length(json_files)} migrated" <>
            if(dry_run?, do: " (dry-run — no files written)", else: "")
        )

        maybe_delete_legacy_tree(legacy_dir, dry_run?, ok_count == length(json_files))
    end
  end

  # Re-key one legacy `<stem>.json` to `world-layouts/<ws>/<stem>`.
  defp migrate_one(legacy_dir, filename, dry_run?) do
    stem = Path.basename(filename, ".json")
    legacy_path = Path.join(legacy_dir, filename)

    with {:ok, body} <- File.read(legacy_path),
         {:ok, %{"scope" => scope_str}} when is_binary(scope_str) <- Jason.decode(body),
         {:ok, ws} <- workspace_name_of(scope_str) do
      dest = Path.join([Ezagent.Home.path(@new_component), ws, stem])

      if dry_run? do
        Mix.shell().info("  would migrate #{filename} → world-layouts/#{ws}/#{stem}")
        :ok
      else
        with :ok <- File.mkdir_p(Path.dirname(dest)),
             :ok <- File.write(dest, body) do
          Mix.shell().info("  migrated #{filename} → world-layouts/#{ws}/#{stem}")
          :ok
        else
          {:error, reason} ->
            Mix.shell().error("  FAILED to write #{dest}: #{inspect(reason)}")
            {:error, reason}
        end
      end
    else
      {:error, reason} ->
        Mix.shell().error("  SKIP #{filename}: #{inspect(reason)}")
        {:error, reason}

      other ->
        Mix.shell().error("  SKIP #{filename}: unrecognized layout (#{inspect(other)})")
        {:error, :unrecognized_layout}
    end
  end

  # Parse an operator's persisted layout "scope" string (a legacy on-disk JSON
  # field) to recover its workspace. The "scope" field stores
  # `URI.to_string(scope_uri)` of a `workspace://<ws>` ezagent-scheme URI
  # (LayoutManager.scope_string/1), so it MUST go through the canonical
  # chokepoint: a malformed/typo'd stored scheme is an operator-visible error
  # worth crashing this one-shot on (#9 / let-it-crash), not a value to
  # tolerate. A stdlib `URI.parse/1` would yield an authority-bearing,
  # unvalidated struct that bypasses the SchemeRegistry + 3-segment check.
  defp workspace_name_of(scope_str) do
    parsed = Ezagent.URI.new!(scope_str)

    case Ezagent.URI.workspace_name(parsed) do
      {:ok, ws} -> {:ok, ws}
      :error -> {:error, {:no_workspace_in_scope, scope_str}}
    end
  end

  defp maybe_delete_legacy_tree(legacy_dir, dry_run?, all_ok?)

  defp maybe_delete_legacy_tree(legacy_dir, true, _all_ok?) do
    Mix.shell().info("  (dry-run) would delete legacy tree #{legacy_dir}")
  end

  defp maybe_delete_legacy_tree(legacy_dir, false, true) do
    File.rm_rf!(legacy_dir)
    Mix.shell().info("✓ Deleted legacy tree #{legacy_dir}")
  end

  defp maybe_delete_legacy_tree(legacy_dir, false, false) do
    Mix.shell().error(
      "Legacy tree #{legacy_dir} NOT deleted — some files did not migrate. " <>
        "Resolve the errors above and re-run."
    )
  end
end
