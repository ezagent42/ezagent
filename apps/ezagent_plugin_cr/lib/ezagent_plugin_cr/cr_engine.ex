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
    with {:ok, cr} <- ensure_active_cr(tid),
         :ok <- CrLint.check(tid),
         {:ok, new_ver} <- CrSnapshot.snapshot(tid),
         # mark-before-flip: persist "publishing" status BEFORE symlink flip.
         # If crash occurs during flip, repair_current/1 detects "publishing"
         # and re-runs the flip without re-snapshotting.
         :ok <- mark_publishing(tid, cr, new_ver),
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
  Detect and heal the mark-before-flip gap: if a CR is marked "publishing"
  but the symlink points to an older version, re-run the flip.
  """
  @spec repair_current(String.t()) :: {:ok, :repaired | :consistent} | {:error, term()}
  def repair_current(tid) do
    case ensure_active_cr(tid) do
      {:ok, %{"status" => "publishing", "published_version" => ver}} ->
        if current_points_to?(tid, ver) do
          # Symlink is already correct — just update status.
          cr = ensure_active_cr!(tid)
          write_cr(tid, cr["cr_id"], Map.put(cr, "status", "published"))
          {:ok, :consistent}
        else
          # Symlink is stale — re-run the flip.
          case update_current(tid, ver) do
            :ok ->
              cr = ensure_active_cr!(tid)
              published = Map.merge(cr, %{
                "status" => "published",
                "published_at" => DateTime.utc_now() |> DateTime.to_iso8601()
              })
              write_cr(tid, cr["cr_id"], published)
              {:ok, :repaired}

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:ok, _cr} ->
        {:ok, :consistent}

      {:error, reason} ->
        {:error, reason}
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
    publishing =
      Map.merge(cr, %{
        "status" => "publishing",
        "published_version" => new_ver,
        "published_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    write_cr(tid, cr["cr_id"], publishing)
  end

  defp current_points_to?(tid, ver) do
    current = TenantRuntime.current_release_path(tid)
    target = Path.join(TenantRuntime.release_path(tid), ver)

    case File.read_link(current) do
      {:ok, link_target} -> link_target == target
      _ -> false
    end
  end

  defp ensure_active_cr!(tid) do
    {:ok, cr} = ensure_active_cr(tid)
    cr
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
