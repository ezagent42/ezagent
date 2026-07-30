defmodule Mix.Tasks.Ezagent.Identity.RotateAdmin do
  @shortdoc "#1627 — rotate the genesis admin's signing key + re-mint its self-license (atomic)"
  @moduledoc """
  Rotate the genesis admin (authority root) signing key.

  The admin is structurally un-killable (#1627 B1-hybrid): revoke / delete /
  regenesis of `admin_uri()` are all rejected. Key rotation is the ONE sanctioned
  way to advance the root's generation — it rotates the authority AND re-mints the
  self-license under the new generation atomically (one transaction under lock),
  so a legitimate rotation never leaves a stale-generation admin window.

      mix ezagent.identity.rotate_admin

  Release nodes (no Mix) use the equivalent:

      bin/ezagent eval "EzagentCore.Release.rotate_admin()"
  """

  use Mix.Task

  @doc false
  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)

    case Ezagent.Identity.AdminKeyRotation.run() do
      {:ok, _generation} ->
        :ok

      {:error, reason} ->
        Mix.raise("admin key rotation failed: #{inspect(reason)}")
    end
  end
end
