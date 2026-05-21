defmodule EzagentPluginEcho.Application do
  @moduledoc """
  Echo plugin OTP application.

  ## Boot sequence

  1. Register `{Ezagent.Entity.Echo, :say|:receive} → Ezagent.Behavior.Echo`
     in `Ezagent.BehaviorRegistry`. Idempotent on hot-reload.
  2. Register the `echo` agent flavor in `SpawnRegistry`'s entity://
     scheme via the chat plugin's three-step resolver (snapshot →
     template → flavor-prefix). Echo's `kind_module_from_flavor("echo")`
     hardcoded in `EzagentDomainChat.Application` already covers this —
     this plugin's contribution is just behavior registration + the
     DynamicSupervisor for spawned instances.
  3. Start the per-Kind DynamicSupervisor so SpawnRegistry-driven
     spawns have a place to live (the chat plugin's `spawn_agent/1`
     routes echo Kinds under `EzagentDomainChat.AgentSupervisor`, not
     this plugin's supervisor — so this DynamicSupervisor is currently
     unused but kept for future per-plugin-supervisor migrations).

  ## PR-M (Allen 2026-05-20) — standardized creation

  Previously this Application's `start/2` called
  `DynamicSupervisor.start_child(__MODULE__.Supervisor, ...)` directly
  to spawn the default echo agent at boot. That bypassed
  `Ezagent.SpawnRegistry.spawn/1` — the same registry every other Kind
  uses — and meant:

  - snapshot rehydration wouldn't reproduce echo_default on next boot
    via the standard path
  - the agent's URI wasn't routed through chat's `spawn_agent/1`
    flavor-resolver (so the Kind landed in this plugin's supervisor
    instead of `EzagentDomainChat.AgentSupervisor`)
  - chat plugin's `entity://` spawn fn never saw the URI, breaking the
    "one path to spawn Kinds" invariant

  PR-M removes the direct spawn here. The chat plugin (last app to
  boot) calls `EzagentPluginEcho.Application.default_uri/0` +
  `Ezagent.SpawnRegistry.spawn/1` post-boot via
  `EzagentDomainChat.Application.ensure_echo_default/0`. The result
  goes through the standard path: chat's `entity://` fn → `spawn_agent/1`
  → flavor-prefix resolver → `EzagentDomainChat.AgentSupervisor`.

  This plugin's only remaining responsibilities:
  - `register_behaviors/0` (the same as before)
  - own the URI constant `@default_uri` (exported via `default_uri/0`)
  - keep `__MODULE__.Supervisor` available as a DynamicSupervisor for
    future per-plugin-supervisor migrations (currently unused at runtime
    since chat owns AgentSupervisor)

  ## Why this app depends on `ezagent_core` via in_umbrella

  Plugin pattern: plugins live alongside `ezagent_core` in the umbrella
  but never reach into core internals — only via the public API
  (`Ezagent.BehaviorRegistry.register`, `Ezagent.SpawnRegistry.spawn`).
  This boundary is what lets future devs work on plugins without
  coordinating with the core team (the north-star feedback rule).
  """

  use Application

  # PR #141 (SPEC v2): `agent://` scheme deleted; merged into `entity://`.
  # Agent flavor moves to free-form name prefix (SPEC §5.14):
  # Echo's default instance is `entity://agent/default/echo_default`.
  @default_uri URI.parse("entity://agent/default/echo_default")

  @impl true
  def start(_type, _args) do
    register_behaviors()
    register_template_classes()

    children = [
      {DynamicSupervisor, name: __MODULE__.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  # Domain.Pty SPEC v1 §10 row 3 + §11 item 6 (deferred PR-D sub-task,
  # now in scope per Allen Feishu 2026-05-22) — register the
  # `echo.agent` Template Class so operators can create echo agents
  # with an optional `/bin/bash -i` PTY sidecar via the standard
  # `Workspace.add_template → invoke_template → instantiate` chain.
  # Direct `SpawnRegistry.spawn/1` (the original creation path) still
  # works unchanged for the default echo agent + legacy callers.
  defp register_template_classes do
    :ok = Ezagent.TemplateRegistry.register(Ezagent.PluginEcho.Template.EchoAgent)
    :ok
  end

  defp register_behaviors do
    # `:say` is the historical programmatic-invoke action (Phase 1
    # contract). `:receive` is the fan-out hook — Session's chat.send
    # dispatches `chat.receive` to every Echo agent in members; without
    # this registration, that dispatch returns `:not_registered` and
    # the echo agent silently drops every chat msg (the regression
    # Allen flagged 2026-05-20).
    :ok = Ezagent.BehaviorRegistry.register(Ezagent.Entity.Echo, :say, Ezagent.Behavior.Echo)
    :ok = Ezagent.BehaviorRegistry.register(Ezagent.Entity.Echo, :receive, Ezagent.Behavior.Echo)
  end

  @doc """
  URI of the default Echo instance — spawned post-boot by the chat
  plugin (PR-M, see moduledoc) via
  `EzagentDomainChat.Application.ensure_echo_default/0`.
  """
  def default_uri, do: @default_uri
end
