defmodule EzagentPluginCr.CrEngine do
  @moduledoc "CR full-publish engine. One active CR per tenant."

  alias EzagentPluginContent.Tenant.{TenantRuntime, TenantConfig}
  alias Ezagent.Socialware.ConfigStore
  alias EzagentPluginCr.{CrLint, CrSnapshot}

  @spec ensure_active_cr(String.t()) :: {:ok, map()} | {:error, term()}
  def ensure_active_cr(tid) do
    case TenantConfig.read_cr(tid, active_cr_id(tid)) do
      {:ok, %{"status" => "open"} = cr} ->
        {:ok, cr}

      _ ->
        cr_id = "cr-#{Date.utc_today()}-#{System.unique_integer([:positive]) |> rem(1000)}"

        cr = %{
          "cr_id" => cr_id,
          "tenant_id" => tid,
          "status" => "open",
          "created_by" => "system://cr-engine",
          "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        write_cr(tid, cr_id, cr)
    end
  end

  @spec publish(String.t()) :: {:ok, map()} | {:error, term()}
  def publish(tid) do
    # Heal any half-finished prior publish before allocating a new version.
    # Adapted from PR #740.
    with {:ok, _} <- repair_current(tid),
         {:ok, cr} <- ensure_active_cr(tid),
         {:ok, _lint_result} <- CrLint.check(tid),
         {:ok, new_ver} <- CrSnapshot.snapshot(tid),
         # mark-before-flip: persist "published vN" status BEFORE symlink flip.
         # If a crash occurs during the flip, repair_current/1 detects the
         # "published vN"-but-stale-pointer gap and re-runs the flip.
         # mark_publishing → write_cr returns `{:ok, cr}` (ConfigStore.write_and_point
         # returns `{:ok, _}` on main), NOT bare `:ok`. Match the 2-tuple so the
         # `with` does not short-circuit here and skip the symlink flip below.
         {:ok, _} <- mark_publishing(tid, cr, new_ver),
         :ok <- update_current(tid, new_ver) do
      published =
        Map.merge(cr, %{
          "status" => "published",
          "published_version" => new_ver,
          "published_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      write_cr(tid, cr["cr_id"], published)
      {:ok, published}
    end
  end

  @doc """
  Detect and heal the mark-before-flip gap: `publish/1` marks the CR
  "published vN" (durable write) BEFORE flipping `_current` → vN. If a CR
  says "published vN" but the symlink still points elsewhere, re-run the flip.

  Reads the CR pointer DIRECTLY (not via `ensure_active_cr/1`, which would
  auto-create a fresh "open" CR and erase the half-finished state we need to
  detect).
  """
  @spec repair_current(String.t()) :: {:ok, :repaired | :consistent} | {:error, term()}
  def repair_current(tid) do
    case TenantConfig.read_cr(tid, active_cr_id(tid)) do
      {:ok, %{"status" => "published", "published_version" => ver} = cr} when is_binary(ver) ->
        if current_points_to?(tid, ver) do
          {:ok, :consistent}
        else
          # Symlink is stale — complete the flip idempotently.
          case update_current(tid, ver) do
            :ok ->
              _ = write_cr(tid, cr["cr_id"], cr)
              {:ok, :repaired}

            {:error, reason} ->
              {:error, reason}
          end
        end

      _ ->
        # No CR, or an open/cancelled CR — nothing half-finished to repair.
        {:ok, :consistent}
    end
  end

  @spec cancel(String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(tid) do
    {:ok, cr} = ensure_active_cr(tid)
    write_cr(tid, cr["cr_id"], Map.put(cr, "status", "cancelled"))
  end

  @doc """
  Compute the diff between sandbox and the current release (`release/_current`).
  Hashes key files and directories to determine which items have changed.
  Returns a map with `:items` (list of change entries) and `:count`.
  """
  @spec compute_sandbox_diff(String.t()) :: %{items: [map()], count: non_neg_integer()}
  def compute_sandbox_diff(tid) do
    sandbox = EzagentPluginContent.Tenant.TenantRuntime.sandbox_path(tid)
    release = Path.join([EzagentPluginContent.Tenant.TenantRuntime.release_path(tid), "_current"])

    items =
      [
        check_file_diff("souls/customer.md", sandbox, release),
        check_file_diff("slots/customer.yaml", sandbox, release),
        check_dir_diff("skills/customer", sandbox, release),
        check_kb_diff(tid, sandbox, release)
      ]
      |> Enum.filter(& &1)

    %{items: items, count: length(items)}
  end

  @doc "Record a sandbox file change on the active CR's sandbox_diff."
  @spec record_file_change(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def record_file_change(tid, path, opts \\ []) do
    with {:ok, cr} <- ensure_active_cr(tid) do
      diff = compute_sandbox_diff(tid)
      existing = cr["sandbox_diff"] || %{}
      new_paths = Enum.uniq((existing["paths"] || []) ++ [path])

      merged = %{
        "files_changed" => diff.count,
        "paths" => new_paths,
        "items" => diff.items,
        "lines_added" => (existing["lines_added"] || 0) + Keyword.get(opts, :lines_added, 0),
        "lines_removed" => (existing["lines_removed"] || 0) + Keyword.get(opts, :lines_removed, 0)
      }

      cr_id = cr["cr_id"]

      updated_cr =
        Map.merge(cr, %{"sandbox_diff" => merged, "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()})

      _ = TenantConfig.update_cr(tid, cr_id, updated_cr)
      :ok
    end
  end

  @doc """
  List all CRs for a tenant, ordered by inserted_at desc.
  Returns a list of CR body maps, each with a "cr_id" key set.
  Queries ConfigObject (immutable, append-only) so historical CR
  versions are retained even after the pointer advances.
  """
  @spec list_crs(String.t()) :: [map()]
  def list_crs(tid) do
    try do
      import Ecto.Query
      alias Ezagent.Socialware.ConfigObject
      alias EzagentCore.Repo

      Repo.all(
        from(o in ConfigObject,
          where: like(o.key, ^"cr:#{tid}:%"),
          order_by: [desc: o.inserted_at],
          select: {o.key, o.body}
        )
      )
      |> Enum.map(fn {key, body} ->
        cr_id = String.replace_prefix(key, "cr:#{tid}:", "")
        body_map = body || %{}
        Map.put(body_map, "cr_id", cr_id)
      end)
    rescue
      _ -> []
    end
  end

  # The local ID passed to TenantConfig.read_cr/2 (which prepends "cr:#{tid}:")
  defp active_cr_id(_tid), do: "active"

  # Full ConfigStore key matching TenantConfig.read_cr/2's construction:
  # ConfigStore.resolve(..., "cr:#{tid}:#{cr_id}")
  defp cr_key(tid), do: "cr:#{tid}:#{active_cr_id(tid)}"

  # Atomic symlink flip via tmp + rename. Adapted from PR #740:
  # `rm → ln_s` is NOT atomic — crash between rm and ln_s orphans `current`.
  # `ln_s(target, tmp)` then `:file.rename(tmp, current)` is atomic on the
  # same filesystem (rename(2)), so `current` always points to a valid dir.
  defp update_current(tid, ver) do
    current = TenantRuntime.current_release_path(tid)
    target = Path.join(TenantRuntime.release_path(tid), ver)

    File.mkdir_p!(target)

    tmp = current <> ".tmp"
    _ = File.rm_rf(tmp)

    with :ok <- File.ln_s(target, tmp),
         :ok <- :file.rename(tmp, current) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm_rf(tmp)
        {:error, "symlink flip failed: #{inspect(reason)}"}
    end
  end

  defp mark_publishing(tid, cr, new_ver) do
    # Durable "published vN" write BEFORE the symlink flip (mark-before-flip).
    marked =
      Map.merge(cr, %{
        "status" => "published",
        "published_version" => new_ver,
        "published_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    write_cr(tid, cr["cr_id"], marked)
  end

  defp current_points_to?(tid, ver) do
    current = TenantRuntime.current_release_path(tid)
    target = Path.join(TenantRuntime.release_path(tid), ver)

    case File.read_link(current) do
      {:ok, link_target} -> link_target == target
      _ -> false
    end
  end

  defp write_cr(tid, _cr_id, cr) do
    # One pointer per tenant: key matches TenantConfig.read_cr/2's construction.
    ConfigStore.write_and_point(%{
      layer: "workspace",
      workspace_uri: "workspace://#{tid}",
      subject_uri: "entity://system/cr",
      key: cr_key(tid),
      body: cr,
      actor_uri: "system://cr-engine",
      source_turn_id: "publish_#{System.unique_integer([:monotonic])}"
    })
    |> case do
      {:ok, _} -> {:ok, cr}
      e -> e
    end
  end

  # --- sandbox diff helpers ---

  defp check_file_diff(rel_path, sandbox, release) do
    s = Path.join(sandbox, rel_path)
    r = Path.join(release, rel_path)
    s_exists = File.exists?(s)
    r_exists = File.exists?(r)

    cond do
      s_exists && r_exists ->
        if hash_file(s) != hash_file(r), do: %{path: rel_path, kind: :modified}, else: nil

      s_exists ->
        %{path: rel_path, kind: :added}

      r_exists ->
        %{path: rel_path, kind: :removed}

      true ->
        nil
    end
  end

  defp check_dir_diff(rel_path, sandbox, release) do
    s_dir = Path.join(sandbox, rel_path)
    r_dir = Path.join(release, rel_path)
    s_exists = File.dir?(s_dir)
    r_exists = File.dir?(r_dir)

    cond do
      s_exists && r_exists ->
        if dir_files_sorted(s_dir) != dir_files_sorted(r_dir),
          do: %{path: rel_path, kind: :dir_modified},
          else: nil

      s_exists ->
        %{path: rel_path, kind: :added}

      r_exists ->
        %{path: rel_path, kind: :removed}

      true ->
        nil
    end
  end

  defp check_kb_diff(_tid, sandbox, release) do
    s = Path.join([sandbox, "kb", "kb.db"])
    r = Path.join([release, "kb", "kb.db"])
    s_exists = File.exists?(s)
    r_exists = File.exists?(r)

    cond do
      s_exists && r_exists ->
        if hash_file(s) != hash_file(r), do: %{path: "kb/kb.db", kind: :modified}, else: nil

      s_exists ->
        %{path: "kb/kb.db", kind: :added}

      r_exists ->
        %{path: "kb/kb.db", kind: :removed}

      true ->
        nil
    end
  end

  defp hash_file(path) do
    File.stream!(path, [], 2048)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp dir_files_sorted(dir) do
    with {:ok, entries} <- File.ls(dir) do
      entries
      |> Enum.filter(&(File.exists?(Path.join(dir, &1)) && !File.dir?(Path.join(dir, &1))))
      |> Enum.sort()
    else
      _ -> []
    end
  end
end
