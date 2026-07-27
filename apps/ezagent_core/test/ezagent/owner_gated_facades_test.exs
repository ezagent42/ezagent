defmodule Ezagent.OwnerGatedFacadesTest do
  @moduledoc """
  Guardrail proof for the owner-gated executor + workspace facades (Phase 2 of
  the plugin owner-bypass burndown):

    * OWNER path (default `LocalResolver`, current runtime owns every workspace)
      is BYTE-IDENTICAL to the un-gated `GenServer.call` / `bind` / `record` —
      same reply, and the target actually receives the call / the write lands.
    * An ENFORCED non-owner violation fails CLOSED per R1: the executor returns
      `{:error, :cross_workspace_denied}` and the target is NEVER called; bind /
      record return `{:error, {:not_workspace_owner, ...}}` and nothing is
      written. No new SUCCESS shape is ever introduced.
  """
  use ExUnit.Case, async: false

  alias Ezagent.{OwnerGatedExecutor, OwnerGatedWorkspace, RuntimeIdentity, WorkspacePlacement}
  alias Ezagent.WorkspaceRegistry

  defmodule RemoteResolver do
    @behaviour Ezagent.WorkspacePlacement

    # Owns ONLY workspace://team-alpha (as a remote node). Matching a single host
    # asserts the facade derives the EXACT expected workspace from each target
    # URI — a wrong derivation (e.g. gating workspace://agent from a malformed
    # entity URI) raises FunctionClauseError here instead of passing silently.
    @impl true
    def owner_of(%URI{scheme: "workspace", host: "team-alpha"}), do: {:ok, "remote-node"}
  end

  # Stand-in for a workspace-bound sidecar/executor GenServer (the cc/codex
  # sidecars, app-server, SessionManager all hold a raw pid like this).
  defmodule Echo do
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(_), do: {:ok, %{calls: 0}}

    @impl true
    def handle_call(:recent_output, _from, s), do: {:reply, "echo-output", bump(s)}
    def handle_call({:query, text}, _from, s), do: {:reply, {:ok, %{content: text}}, bump(s)}
    def handle_call(:call_count, _from, s), do: {:reply, s.calls, s}

    defp bump(s), do: %{s | calls: s.calls + 1}
  end

  setup do
    previous_identity = Application.get_env(:ezagent_core, RuntimeIdentity)
    previous_placement = Application.get_env(:ezagent_core, WorkspacePlacement)

    on_exit(fn ->
      restore_env(RuntimeIdentity, previous_identity)
      restore_env(WorkspacePlacement, previous_placement)
    end)

    {:ok, echo} = start_supervised(Echo)
    # Real URI shapes (workspace-first): entity://<workspace>/agent/<name> and
    # session://<workspace>/<template>/<name> — both derive workspace://team-alpha.
    # Uniqueness goes in the NAME segment (not the workspace/host) so the
    # `session://<X>` 1-segment grep gate (all_per_tenant_uris_have_workspace)
    # sees `session://team-alpha/…` — host followed by `/`, not an interpolation.
    n = System.unique_integer([:positive])

    %{
      echo: echo,
      agent_uri: Ezagent.URI.new!("entity://team-alpha/agent/a1-#{n}"),
      session_uri: Ezagent.URI.new!("session://team-alpha/default/facade-#{n}"),
      workspace_uri: Ezagent.URI.new!("workspace://team-alpha")
    }
  end

  # ── OWNER path: byte-identical delegation ────────────────────────────────

  test "OwnerGatedExecutor.call/4 is byte-identical to GenServer.call on the owner path",
       %{echo: pid, agent_uri: uri} do
    assert "echo-output" == OwnerGatedExecutor.call(uri, pid, :recent_output, 1_000)
    assert {:ok, %{content: "hi"}} == OwnerGatedExecutor.call(uri, pid, {:query, "hi"}, 1_000)
    # The target actually received both calls (delegation happened).
    assert GenServer.call(pid, :call_count) == 2
  end

  test "OwnerGatedWorkspace.bind/2 binds on the owner path",
       %{session_uri: session_uri, workspace_uri: workspace_uri} do
    assert :ok == OwnerGatedWorkspace.bind(session_uri, workspace_uri)
    assert {:ok, ^workspace_uri} = WorkspaceRegistry.lookup(session_uri)
    WorkspaceRegistry.unbind(session_uri)
  end

  # ── ENFORCED non-owner: fail-closed, no side effects ─────────────────────

  test "OwnerGatedExecutor.call/4 fails closed and never calls the target off-owner",
       %{echo: pid, agent_uri: uri} do
    put_remote_owner()

    assert {:error, :cross_workspace_denied} ==
             OwnerGatedExecutor.call(uri, pid, :recent_output, 1_000)

    assert {:error, :cross_workspace_denied} ==
             OwnerGatedExecutor.call(uri, pid, {:query, "hi"}, 1_000)

    # Short-circuited BEFORE the pid: the target was never called.
    assert GenServer.call(pid, :call_count) == 0
  end

  test "OwnerGatedWorkspace.bind/2 fails closed and writes nothing off-owner",
       %{session_uri: session_uri, workspace_uri: workspace_uri} do
    put_remote_owner()

    assert {:error,
            {:not_workspace_owner, _ws, "remote-node", "test-node-a",
             {:workspace_bind, ^session_uri}}} =
             OwnerGatedWorkspace.bind(session_uri, workspace_uri)

    assert :error == WorkspaceRegistry.lookup(session_uri)
  end

  test "OwnerGatedWorkspace.record_lineage/2 fails closed off-owner (short-circuits the write)",
       %{agent_uri: agent_uri} do
    put_remote_owner()
    spawned_by = Ezagent.URI.new!("entity://team-alpha/agent/admin")

    assert {:error,
            {:not_workspace_owner, _ws, "remote-node", "test-node-a",
             {:lineage_record, ^agent_uri}}} =
             OwnerGatedWorkspace.record_lineage(agent_uri, spawned_by)
  end

  defp put_remote_owner do
    Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "test-node-a")
    Application.put_env(:ezagent_core, WorkspacePlacement, resolver: RemoteResolver)
  end

  defp restore_env(module, nil), do: Application.delete_env(:ezagent_core, module)
  defp restore_env(module, value), do: Application.put_env(:ezagent_core, module, value)
end
