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

  defp update_current(tid, ver) do
    current = TenantRuntime.current_release_path(tid)
    target = Path.join(TenantRuntime.release_path(tid), ver)

    # Ensure the release directory exists (CrSnapshot creates it in non-stub path, but
    # guard here in case it does not).
    File.mkdir_p!(target)

    if File.exists?(current), do: File.rm!(current)

    case File.ln_s(target, current) do
      :ok -> :ok
      {:error, reason} -> {:error, "symlink failed: #{inspect(reason)}"}
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
