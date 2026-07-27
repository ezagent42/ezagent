defmodule Ezagent.OwnerGatedExecutor do
  @moduledoc """
  Owner-gated `GenServer.call/3` to a workspace-bound runtime process addressed
  by URI.

  Plugins hold raw pids to per-agent sidecars/executors (the cc SDK sidecar, the
  codex bridge sidecar and app-server, the cc SessionManager) resolved from
  plugin-local, URI-keyed registries. Those processes are NOT Kinds, so
  `Ezagent.Invocation.dispatch/1` cannot reach them — but a plugin still must not
  call a workspace-bound pid without passing the workspace owner gate. This is
  the core seam that does exactly that: assert the current runtime owns the
  target URI's workspace, then issue the identical `GenServer.call(pid, message,
  timeout)` the plugin would have issued.

  On the owner path — and whenever the gate is in `:observe` mode — the call is
  byte-identical to a direct `GenServer.call/3`: same message, same timeout, same
  reply, same exits (a dead target or a `:timeout` still propagates, so the
  caller's own `catch`/fallback is unchanged). It short-circuits fail-closed with
  `{:error, :cross_workspace_denied}` — the same signal `Ezagent.Invocation` uses
  for a cross-workspace dispatch, never a new success shape — for BOTH an enforced
  non-owner violation AND a URI that derives no concrete workspace (`:any` /
  `system://`): a workspace-bound executor call cannot be ownership-verified
  without a real workspace, so it is denied rather than let through. Callers map
  that sentinel onto their own contract (a status read returns `""`, a query
  returns the error tuple).
  """

  @doc """
  Owner-gate `uri`'s workspace, then `GenServer.call(pid, message, timeout)`.

  Returns the raw call reply on the owner/observe path, or
  `{:error, :cross_workspace_denied}` on a non-owner violation or a URI with no
  concrete workspace (`:any` / `system://`).
  """
  @spec call(URI.t(), pid(), term(), timeout()) :: term() | {:error, :cross_workspace_denied}
  def call(%URI{} = uri, pid, message, timeout) when is_pid(pid) do
    with %URI{scheme: "workspace"} = ws <- Ezagent.URI.workspace_of(uri),
         :ok <- Ezagent.WorkspaceOwnerGate.assert_local_owner(ws, {:executor_call, uri}) do
      GenServer.call(pid, message, timeout)
    else
      # No concrete workspace (:any / system://) or a non-owner violation — a
      # workspace-bound executor call cannot be ownership-verified, so fail closed.
      _ -> {:error, :cross_workspace_denied}
    end
  end
end
