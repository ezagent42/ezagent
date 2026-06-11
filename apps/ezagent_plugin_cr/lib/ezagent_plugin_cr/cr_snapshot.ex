defmodule EzagentPluginCr.CrSnapshot do
  @moduledoc """
  Copy tenant sandbox to a numbered release directory for snapshotting.

  `cp -r sandbox/ -> release/v<N>/`.
  """

  alias EzagentPluginContent.Tenant.TenantRuntime

  @doc """
  Snapshot the tenant's sandbox to a new numbered release version.
  Returns `{:ok, version}` on success or `{:error, reason}`.
  """
  @spec snapshot(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def snapshot(tid) do
    sandbox = TenantRuntime.sandbox_path(tid)
    release = TenantRuntime.release_path(tid)

    # Determine next version number
    existing = Path.join(release, "v*") |> Path.wildcard()
    ver = "v#{length(existing) + 1}"
    target = Path.join(release, ver)

    if File.exists?(sandbox) do
      File.mkdir_p!(release)

      case File.cp_r(sandbox, target) do
        {:ok, _paths} -> {:ok, ver}
        {:error, reason, _path} -> {:error, "snapshot copy failed: #{inspect(reason)}"}
      end
    else
      # No sandbox yet — create an empty release directory
      File.mkdir_p!(target)
      {:ok, ver}
    end
  end
end
