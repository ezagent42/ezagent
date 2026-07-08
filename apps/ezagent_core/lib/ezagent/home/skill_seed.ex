defmodule Ezagent.Home.SkillSeed do
  @moduledoc """
  Deploy-seed installer for shipped agent skill directories.

  Shipped source bytes live under loaded apps' `priv/skills_seed/<ref>/`.
  This module materializes them into the single runtime origin,
  `$EZAGENT_HOME/<profile>/skills/<ref>/`, with crash-safe staging and a
  shipped-hash reconcile that preserves operator edits.
  """

  require Logger

  alias Ezagent.SkillRegistry
  alias Ezagent.Socialware.ConfigStore

  @compile {:no_warn_undefined, Ezagent.Socialware.ConfigStore}

  @layer "workspace"
  @key "skill"
  @seed_family_prefix "skill-seed"
  @actor "entity://system/user/admin"

  @doc """
  Run the boot skill lane: recover crash residue, seed/upgrade bytes, then scan
  the runtime origin into `Ezagent.SkillRegistry`.
  """
  @spec boot!(keyword()) :: :ok
  def boot!(opts \\ []) do
    dest = dest_dir(opts)
    _ = seed!(Keyword.put(opts, :dest, dest))
    SkillRegistry.refresh!(runtime_dir: dest)
  end

  @doc """
  Recover crash residue in the runtime skills directory.

  Recovery is re-entrant: staging directories are always deleted; `.old-*`
  residues restore the old complete ref when the main ref is absent, or are
  deleted when the main ref is present.
  """
  @spec recover!(keyword()) :: :ok
  def recover!(opts \\ []) do
    dest = dest_dir(opts)
    File.mkdir_p!(dest)

    dest
    |> children()
    |> Enum.filter(&intermediate?(&1, ".staging-"))
    |> Enum.each(fn child -> File.rm_rf!(Path.join(dest, child)) end)

    old_groups =
      dest
      |> children()
      |> Enum.filter(&intermediate?(&1, ".old-"))
      |> Enum.group_by(&ref_from_old!/1)

    Enum.each(old_groups, fn {ref, old_names} ->
      target = Path.join(dest, ref)
      sorted_old_names = Enum.sort(old_names)

      cond do
        File.exists?(target) ->
          Enum.each(sorted_old_names, fn old -> File.rm_rf!(Path.join(dest, old)) end)

        sorted_old_names != [] ->
          [restore | rest] = sorted_old_names
          File.rename!(Path.join(dest, restore), target)
          Enum.each(rest, fn old -> File.rm_rf!(Path.join(dest, old)) end)
      end
    end)

    :ok
  end

  @doc """
  Seed or reconcile every shipped skill into the runtime origin.

  Options:

    * `:source` — single shipped source dir, for tests.
    * `:dest` — runtime skills dir, for tests.
    * `:index?` — whether to update ConfigStore index objects, default `true`.

  Returns `:ok` when any bytes were seeded/upgraded, `{:ok, :exists}` for a pure
  no-op, or `{:ok, :preserved}` when operator-edited bytes were preserved.
  """
  @spec seed!(keyword()) :: :ok | {:ok, :exists | :preserved}
  def seed!(opts \\ []) do
    dest = dest_dir(opts)
    index? = Keyword.get(opts, :index?, true)

    recover!(dest: dest)
    File.mkdir_p!(dest)

    opts
    |> source_dirs()
    |> Enum.flat_map(&skill_source_dirs/1)
    |> Enum.map(&seed_one(&1, dest, index?))
    |> aggregate_result()
  end

  @doc "Resolve the deployment runtime skills directory through `system://skills`."
  @spec dest_dir(keyword()) :: Path.t()
  def dest_dir(opts \\ []) do
    Keyword.get_lazy(opts, :dest, fn ->
      Ezagent.System.FsResolver.path!(Ezagent.URI.system_principal("skills"))
    end)
  end

  defp source_dirs(opts) do
    case Keyword.get(opts, :source) do
      nil -> SkillRegistry.seed_source_dirs()
      source when is_binary(source) -> [source]
    end
  end

  defp skill_source_dirs(source) do
    if File.dir?(source) do
      source
      |> Path.join("*")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        File.dir?(path) and File.regular?(Path.join(path, "SKILL.md"))
      end)
    else
      []
    end
  end

  defp seed_one(source, dest, index?) do
    ref = Path.basename(source)
    target = Path.join(dest, ref)
    release_hash = SkillRegistry.dir_hash(source)

    case File.dir?(target) do
      false ->
        atomic_replace(source, target, :fresh)
        maybe_upsert_index(index?, ref, release_hash, release_hash)
        :seeded

      true ->
        reconcile_existing(source, target, ref, release_hash, index?)
    end
  end

  defp reconcile_existing(source, target, ref, release_hash, index?) do
    on_disk_hash = SkillRegistry.dir_hash(target)
    shipped_hash = stored_shipped_hash(ref, index?) || on_disk_hash

    cond do
      on_disk_hash == shipped_hash and release_hash == shipped_hash ->
        maybe_upsert_index(index?, ref, on_disk_hash, shipped_hash)
        :exists

      on_disk_hash == shipped_hash and release_hash != shipped_hash ->
        atomic_replace(source, target, :upgrade)
        maybe_upsert_index(index?, ref, release_hash, release_hash)
        :seeded

      on_disk_hash != shipped_hash and release_hash == shipped_hash ->
        maybe_upsert_index(index?, ref, on_disk_hash, shipped_hash)
        :preserved

      true ->
        warn_skipped_upgrade(ref, on_disk_hash, shipped_hash, release_hash)
        maybe_upsert_index(index?, ref, on_disk_hash, shipped_hash)
        :preserved
    end
  end

  defp atomic_replace(source, target, mode) do
    staging = "#{target}.staging-#{nonce()}"
    File.rm_rf!(staging)
    File.cp_r!(source, staging)

    case mode do
      :fresh ->
        File.rename!(staging, target)

      :upgrade ->
        old = "#{target}.old-#{nonce()}"
        File.rename!(target, old)
        File.rename!(staging, target)
        File.rm_rf!(old)
    end
  end

  defp maybe_upsert_index(false, _ref, _content_hash, _shipped_hash), do: :ok

  defp maybe_upsert_index(true, ref, content_hash, shipped_hash) do
    body = %{"ref" => ref, "content_hash" => content_hash, "shipped_hash" => shipped_hash}

    case ConfigStore.seed_object_upsert(%{
           layer: @layer,
           workspace_uri: system_workspace_uri(),
           subject_uri: subject_uri(ref),
           key: @key,
           body: body,
           actor_uri: @actor,
           source_turn_id: "#{@seed_family_prefix}:#{system_workspace_uri()}:#{ref}",
           upgrade_source_turn_id:
             "#{@seed_family_prefix}-upgrade:#{system_workspace_uri()}:#{ref}:#{content_hash}:#{shipped_hash}",
           collision_tag: {:skill_seed_collision, ref},
           seed_family_prefix: @seed_family_prefix
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "skill seed index upsert failed for #{ref}: #{inspect(reason)}"
    end
  end

  defp stored_shipped_hash(_ref, false), do: nil

  defp stored_shipped_hash(ref, true) do
    case ConfigStore.resolve(@layer, system_workspace_uri(), subject_uri(ref), @key) do
      {:ok, %{body: %{"shipped_hash" => hash}}} when is_binary(hash) -> hash
      _ -> nil
    end
  end

  defp warn_skipped_upgrade(ref, on_disk_hash, shipped_hash, release_hash) do
    Logger.warning(
      "skill-seed: SKIPPED release upgrade for #{ref} — operator-edited on disk " <>
        "(on_disk=#{short(on_disk_hash)} shipped=#{short(shipped_hash)} release=#{short(release_hash)}); " <>
        "operator edit preserved, release change NOT applied"
    )

    :telemetry.execute(
      [:ezagent, :skill_seed, :upgrade_skipped],
      %{count: 1},
      %{
        ref: ref,
        on_disk_hash: on_disk_hash,
        shipped_hash: shipped_hash,
        release_hash: release_hash
      }
    )
  end

  defp aggregate_result([]), do: {:ok, :exists}

  defp aggregate_result(results) do
    cond do
      Enum.any?(results, &(&1 == :seeded)) -> :ok
      Enum.any?(results, &(&1 == :preserved)) -> {:ok, :preserved}
      true -> {:ok, :exists}
    end
  end

  defp children(dir) do
    if File.dir?(dir), do: File.ls!(dir), else: []
  end

  defp intermediate?(name, marker), do: String.contains?(name, marker)

  defp ref_from_old!(name) do
    [ref, _nonce] = String.split(name, ".old-", parts: 2)
    ref
  end

  defp subject_uri(ref), do: "skill:#{ref}"

  defp system_workspace_uri, do: :system |> Ezagent.URI.workspace() |> URI.to_string()

  defp nonce, do: System.unique_integer([:positive, :monotonic])

  defp short(hash), do: String.slice(hash, 0, 8)
end
