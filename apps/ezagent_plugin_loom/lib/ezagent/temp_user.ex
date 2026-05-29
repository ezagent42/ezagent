defmodule EzagentPluginLoom.TempUser do
  @moduledoc """
  Browser temp-user lifecycle (loom v0.2, G-A — lightweight path).

  A per-visitor temp user is just a regular `Ezagent.Entity.User`
  instance at `entity://user/<ws>/tmp_<id>`, provisioned with the User
  Kind's structural `default_caps/1` (so it may `chat.send` into a
  same-workspace session — `{:session, :any, :any}` workspace-scoped).
  No new Kind / no ephemeral-persistence primitive is introduced (G-A
  was flagged "无现成机制" in the PRD, but the composition is: spawn a
  normal User + reclaim it later — no architectural Decision needed).

  **Isolation** is NOT enforced here — it is enforced at the mirror-WS
  layer (G-B/S6): the `ws_token` binds a connection to ONE
  `session_uri`, and the server derives the sender from the token. This
  module only mints + reclaims the principal.

  **Reclaim**: not wired — temp users are not reclaimed in the current
  backend-only flow (they accumulate; there's no session-end hook). A
  periodic idle-sweep would be future work, and would need a row-delete
  helper in the identity domain — intentionally NOT added (the identity
  domain is kept untouched).
  """

  require Logger

  alias Ezagent.Users

  @doc """
  Build a fresh temp-user URI in `workspace_name`:
  `entity://user/<ws>/tmp_<12-hex>`. Pure (no side effects) — the
  random id makes each visitor distinct.
  """
  @spec temp_uri(String.t()) :: URI.t()
  def temp_uri(workspace_name) when is_binary(workspace_name) and workspace_name != "" do
    id = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    URI.parse("entity://user/#{workspace_name}/tmp_#{id}")
  end

  @doc """
  Provision a new temp user in `workspace_name`: write its `users` row
  (auto-prepended `default_caps/1` → session-chat authority) then spawn
  the User Kind (which hydrates caps from that row). Returns the URI.
  """
  @spec provision(String.t()) :: {:ok, URI.t()} | {:error, term()}
  def provision(workspace_name) when is_binary(workspace_name) and workspace_name != "" do
    uri = temp_uri(workspace_name)

    with {:ok, _decoded} <- Users.create(uri, nil, []),
         {:ok, _pid} <- spawn_user(uri) do
      {:ok, uri}
    end
  end

  def provision(_), do: {:error, :invalid_workspace}

  defp spawn_user(%URI{} = uri) do
    case Ezagent.SpawnRegistry.spawn(uri) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end
end
