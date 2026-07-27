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
  caller's own `catch`/fallback is unchanged). Only an ENFORCED non-owner
  violation short-circuits, returning `{:error, :cross_workspace_denied}` — the
  same signal `Ezagent.Invocation` uses for a cross-workspace dispatch — never a
  new success shape. Callers map that sentinel onto their own contract
  fail-closed (e.g. a status read returns `""`, a query returns the error tuple).
  """

  @doc """
  Owner-gate `uri`'s workspace, then `GenServer.call(pid, message, timeout)`.

  Returns the raw call reply on the owner/observe path, or
  `{:error, :cross_workspace_denied}` on an enforced non-owner violation.
  """
  @spec call(URI.t(), pid(), term(), timeout()) :: term() | {:error, :cross_workspace_denied}
  def call(%URI{} = uri, pid, message, timeout) when is_pid(pid) do
    case Ezagent.WorkspaceOwnerGate.assert_local_owner_for_uri(uri, {:executor_call, uri}) do
      :ok -> GenServer.call(pid, message, timeout)
      {:error, _violation} -> {:error, :cross_workspace_denied}
    end
  end
end
