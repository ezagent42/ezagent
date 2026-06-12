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
    with {:ok, _} <- repair_current(tid),
         {:ok, cr} <- ensure_active_cr(tid),
         :ok <- CrLint.check(tid),
         {:ok, new_ver} <- CrSnapshot.snapshot(tid),
         # Mark-before-flip: durably record "this version is published" in the
         # CR pointer BEFORE flipping _current. A crash between the two steps
         # leaves the CR saying "published vN" while _current still points at
         # vN-1; repair_current/1 detects that gap and completes the flip
         # idempotently (vN dir is already fully materialized by snapshot).
         #
         # The opposite ordering (flip → mark) is unrecoverable: a crash after
         # flip but before the CR write leaves _current at vN with the CR still
         # reading the previous version, and nothing on disk records that vN was
         # meant to be the published one.
         published =
           Map.merge(cr, %{
             "status" => "published",
             "published_version" => new_ver,
             "published_at" => DateTime.utc_now() |> DateTime.to_iso8601()
           }),
         {:ok, _} <- write_cr(tid, cr["cr_id"], published),
         :ok <- update_current(tid, new_ver) do
      {:ok, published}
    end
  end

  @doc """
  Detect and heal a half-finished publish (the mark-before-flip gap).

  Reads the tenant's active CR pointer. If it is `"published"` at version
  `vN`, the `vN` release dir exists, but `_current` does not already resolve to
  it, completes the flip and returns `{:ok, :repaired}`. Otherwise returns
  `{:ok, :consistent}` (already pointing, no published CR yet, or the `vN` dir
  is missing — in which case there is nothing to complete).

  Idempotent: safe to call on every `publish/1` and at startup.
  """
  @spec repair_current(String.t()) :: {:ok, :repaired | :consistent} | {:error, term()}
  def repair_current(tid) do
    case TenantConfig.read_cr(tid, active_cr_id(tid)) do
      {:ok, %{"status" => "published", "published_version" => ver}} when is_binary(ver) ->
        target = Path.join(TenantRuntime.release_path(tid), ver)
        current = TenantRuntime.current_release_path(tid)

        cond do
          # No materialized version to point at — nothing to complete.
          not File.dir?(target) ->
            {:ok, :consistent}

          # _current already resolves to the published version — consistent.
          resolves_to?(current, target) ->
            {:ok, :consistent}

          true ->
            case update_current(tid, ver) do
              :ok -> {:ok, :repaired}
              err -> err
            end
        end

      _ ->
        {:ok, :consistent}
    end
  end

  @spec cancel(String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(tid) do
    {:ok, cr} = ensure_active_cr(tid)
    write_cr(tid, cr["cr_id"], Map.put(cr, "status", "cancelled"))
  end

  # The local ID passed to TenantConfig.read_cr/2 (which prepends "cr:#{tid}:")
  defp active_cr_id(_tid), do: "active"

  # Full ConfigStore key matching TenantConfig.read_cr/2's construction:
  # ConfigStore.resolve(..., "cr:#{tid}:#{cr_id}")
  defp cr_key(tid), do: "cr:#{tid}:#{active_cr_id(tid)}"

  # Atomically flip _current → release/<ver>.
  #
  # Create the symlink at a temp path then rename it over _current. rename(2)
  # is atomic on POSIX, so a crash never leaves _current dangling (the old
  # gap: rm _current → crash → no _current). This makes the flip step itself
  # crash-safe; mark-before-flip + repair_current handle a crash BETWEEN the
  # CR write and this flip.
  defp update_current(tid, ver) do
    current = TenantRuntime.current_release_path(tid)
    target = Path.join(TenantRuntime.release_path(tid), ver)

    # Ensure the release directory exists (CrSnapshot creates it in non-stub path, but
    # guard here in case it does not).
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

  # True when `current` (a symlink) resolves to the same dir as `target`.
  defp resolves_to?(current, target) do
    case File.read_link(current) do
      {:ok, dest} -> Path.expand(dest) == Path.expand(target)
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
      source_turn_id: "publish"
    })
    |> case do
      {:ok, _} -> {:ok, cr}
      e -> e
    end
  end
end
