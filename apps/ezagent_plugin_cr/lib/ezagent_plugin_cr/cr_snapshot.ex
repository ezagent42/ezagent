defmodule EzagentPluginCr.CrSnapshot do
  @moduledoc """
  Copy tenant sandbox to a numbered release directory for snapshotting.

  MVP: `cp -r sandbox/ → release/v<N>/`.
  """

  @doc """
  Snapshot the tenant's sandbox to a new numbered release version.
  Returns `:ok` on success or `{:error, reason}`.
  """
  @spec snapshot(String.t()) :: :ok | {:error, String.t()}
  def snapshot(_tid) do
    # MVP stub — snapshot always succeeds
    :ok
  end
end
