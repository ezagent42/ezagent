defmodule EzagentPluginCr.CrRollback do
  @moduledoc """
  Rollback the tenant release `_current` symlink to a prior version.

  `ln -sf release/v<old> -> _current`.
  """

  alias EzagentPluginContent.Tenant.TenantRuntime

  @doc """
  Point the _current symlink at the named release version.
  Returns `:ok` on success or `{:error, reason}`.
  """
  @spec rollback(String.t(), String.t()) :: :ok | {:error, String.t()}
  def rollback(tid, version) do
    current = TenantRuntime.current_release_path(tid)
    target = Path.join(TenantRuntime.release_path(tid), version)

    unless File.exists?(target) do
      {:error, "release version not found: #{version}"}
    else
      if File.exists?(current), do: File.rm!(current)

      case File.ln_s(target, current) do
        :ok -> :ok
        {:error, reason} -> {:error, "symlink failed: #{inspect(reason)}"}
      end
    end
  end
end
