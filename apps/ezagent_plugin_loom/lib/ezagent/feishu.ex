defmodule EzagentPluginLoom.Feishu do
  @moduledoc """
  Loom v0.2 — bind a bootstrapped session to the demo Feishu group so its
  chat mirrors out one-way (PRD §5.4, 只看不回).

  **Direct `BindingRow.insert` + Worker spawn** — NOT the cap-checked
  `Ezagent.ExternalMirror.bind/4` facade, because that facade runs the
  Feishu adapter's `target_ownership_check`, which resolves the CALLER to
  a Feishu `open_id` via `UserBinding` — and a system/temp bootstrap
  caller has no Feishu identity → `:no_feishu_identity`. The PRD's path is
  "直接写 external_mirror_bindings 行"; outbound mirroring only needs the
  bot token (feishu.yaml creds) + a live Worker, not a per-caller
  membership check.

  Target group is `FEISHU_SYNC_CHAT_ID` env or the documented demo group.
  All per-visitor sessions mirror to this ONE group (noisy by design — a
  demo observability sink).
  """

  require Logger

  alias Ezagent.ExternalMirror.BindingRow

  @adapter_id "feishu"
  @default_chat_id "oc_5bfa5d92a6a26ed3a75aaa2b1a12158f"

  @doc "The Feishu group chat_id all sessions mirror into (env-overridable)."
  def chat_id, do: System.get_env("FEISHU_SYNC_CHAT_ID") || @default_chat_id

  @doc """
  Bind `session_uri` to the Feishu group: insert the projection row +
  ensure the per-binding Worker is alive (both idempotent). Best-effort —
  the caller should not fail bootstrap if this returns `{:error, _}`.
  """
  @spec bind(URI.t()) :: :ok | {:error, term()}
  def bind(%URI{} = session_uri) do
    cid = chat_id()

    attrs = %{
      id: BindingRow.row_id(session_uri, @adapter_id, cid),
      session_uri: URI.to_string(session_uri),
      adapter_id: @adapter_id,
      target_id: cid,
      opts_json: "{}",
      bound_by: URI.to_string(Ezagent.SystemPrincipal.uri("session-internal")),
      bound_at: DateTime.utc_now(),
      workspace_uri: workspace_uri_str(session_uri)
    }

    case BindingRow.insert(attrs) do
      {:ok, _row} -> spawn_worker(session_uri, cid)
      # Unique-key conflict = already bound → still ensure the Worker lives.
      {:error, %Ecto.Changeset{}} -> spawn_worker(session_uri, cid)
      {:error, reason} -> {:error, {:binding_insert_failed, reason}}
    end
  end

  # Spawn the per-binding Worker via the ExternalMirror domain's own
  # two-tier spawn entry (RootSupervisor → PerBindingSupervisor). NOT
  # `Ezagent.Kind.spawn/2` directly — that bypasses `WorkerSpawn`'s arg
  # assembly: the Worker Kind needs its derived `:uri` (only
  # `WorkerSpawn.spawn/4` computes `entity://worker/<ws>/em_<hash>`), so
  # a raw `Kind.spawn` crashes `Kind.Server.init` with `{:badkey, :uri}`.
  # This is the SAME entry `AdapterInstall.reconcile_persisted_bindings/1`
  # uses; idempotent (`{:already_started, _}` on re-bind).
  defp spawn_worker(session_uri, cid) do
    case Ezagent.ExternalMirror.WorkerSpawn.spawn(session_uri, @adapter_id, cid, %{}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, {:worker_spawn_failed, reason}}
    end
  end

  defp workspace_uri_str(session_uri) do
    case Ezagent.Persistence.workspace_uri_for(session_uri) do
      {:ok, ws} when is_binary(ws) -> ws
      {:ok, %URI{} = ws} -> URI.to_string(ws)
      _ -> "workspace://system"
    end
  end
end
