defmodule EzagentPluginEcho.Application do
  @moduledoc """
  Echo plugin OTP application — the `Ezagent.Plugin` contract module.

  ## Plugin authoring contract (PR-2)

  Per the plugin authoring contract SPEC
  (`docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`,
  §3 / §8 Q3 — Allen confirmed: the OTP `Application` module IS the
  plugin contract module) this module `use`s **both** `Application`
  (OTP plumbing) and `Ezagent.Plugin` (the declarative contract).

  Registration is no longer imperative. `start/2` collapses to
  `Ezagent.Plugin.boot(__MODULE__)`; the framework's two-phase
  `boot/1` reads the declaration callbacks below and performs every
  `*Registry` call — the plugin author never touches a registry API
  (the plugin-isolation north star, made structural). The
  `:ezagent_plugin_check` Mix compiler (wired into `mix.exs`) is the
  non-bypassable gate that enforces this.

  ## What this plugin declares

  - `behaviors/0` — `{Ezagent.Entity.Agent, :say|:write}` →
    `Ezagent.Behavior.Echo` / `Ezagent.Behavior.Pty`. A3 reparents echo
    action bindings onto the unified `Ezagent.Entity.Agent` Kind (mirroring
    curl PR-6+7). `:say` is the historical programmatic-invoke action;
    `:write` is the PTY sidecar. `:receive` is intentionally ABSENT here
    because `{Entity.Agent, :receive}` is globally owned by
    `Ezagent.Behavior.Agent.Receive` (registered by `EzagentDomainAgent`),
    the flavor-blind delivery seam → `AgentBridge`. Registering it again
    would cause a capability-conflict boot crash (mirror of curl PR-6+7
    which also omits `:receive` from its `behaviors/0`).
  - `template_classes/0` — the `echo.agent` Template Class, so
    operators can create echo agents (optionally with a `/bin/bash -i`
    PTY sidecar) via the standard add-template chain.
  - `agent_flavors/0` — flavor `"echo"` → `{Ezagent.Entity.Agent,
    Ezagent.PluginEcho.Template.EchoAgent, instance_behaviors:
    &Ezagent.Entity.Agent.echo_behaviors/0}`. A3 migrates the kind to
    the shared `Entity.Agent` and threads the per-instance behavior thunk
    (same pattern as the curl plugin). `Entity.Echo` is kept alive until
    A5 (deletion gate). Consumed by `Ezagent.AgentFlavorRegistry`.
  - `config_surface/0` — `:flavor` surface. The `/plugins` config icon
    routes to this flavor's agent surface (SPEC §6.1).
  - `children/0` — a per-Kind `DynamicSupervisor`. Kept for future
    per-plugin-supervisor migrations; echo Kinds currently land under
    `EzagentDomainInstanceMessage.AgentSupervisor` (chat's flavor-prefix resolver
    routes them there — A5: `Entity.Echo` deleted; echo Kinds land under
    the standard `Entity.Agent` supervisor path).

  ## Default echo agent seeding — `after_boot/0` (PR-5 codex HIGH-2)

  Echo's default instance is spawned in this plugin's `after_boot/0`
  (Phase 3 of `Ezagent.Plugin.boot/1`). It was previously seeded from
  `EzagentDomainInstanceMessage.Application.start/2`, but that was a boot-order
  race: chat's seed needs `Ezagent.AgentFlavorRegistry.lookup("echo")`
  — published by THIS plugin's `boot/1` — and `ezagent_domain_session`
  does not depend on `ezagent_plugin_echo`, so the seed could fire
  before echo's `agent_flavors/0` was registered and fail with
  `{:no_kind_module_for_agent, ...}`, never retried.

  `after_boot/0` runs in Phase 3 — AFTER this plugin's Phase-2
  `publish/1` registered `agent_flavors/0`, so the resolver can map
  the flavor. This plugin declares a dep on `ezagent_domain_session` (a
  pure boot-order constraint — no chat code is referenced), so OTP
  boots chat first and the `entity://` `SpawnRegistry` dispatcher is
  published by the time `after_boot/0` runs. The spawn therefore goes
  through the standard `entity://` resolver path.
  """

  use Application
  use Ezagent.Plugin

  # PR #141 (SPEC v2): `agent://` scheme deleted; merged into `entity://`.
  # Agent flavor moves to free-form name prefix (SPEC §5.14):
  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract ---------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "echo",
      name: "Echo",
      description: "Test stub — echoes back messages.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors do
    # A3 fix — `:receive` is intentionally absent. `{Entity.Agent, :receive}` is
    # globally owned by `Ezagent.Behavior.Agent.Receive` (registered by
    # `EzagentDomainAgent.Application`); re-registering it here causes a
    # capability-conflict boot crash. The echo flavor's inbound delivery flows
    # through `Agent.Receive` → `AgentBridge` → the echo adapter (same as curl).
    #
    # A8 note — `:sync_result` is NOT registered here. `{Entity.Agent,
    # :sync_result}` is already globally bound to `Behavior.CurlAgent` by
    # `EzagentPluginCurlAgent.Application`; re-registering it here would cause
    # a capability-conflict boot crash (same invariant as `:receive`). The
    # deferred `:sync_result` `:cast` that `Behavior.Agent.Receive` enqueues
    # for all `:in_process_sync` adapters will fail with
    # `{:behavior_not_in_instance_set}` for echo agents (curl behavior is not
    # in echo's instance set) — a best-effort silent drop. Echo's echo reply
    # is already fired synchronously inside `BridgeAdapter.deliver/2` before
    # the `:sync_result` re-dispatch is even enqueued, so the drop is harmless.
    [
      {Ezagent.Entity.Agent, :say, Ezagent.Behavior.Echo},
      {Ezagent.Entity.Agent, :write, Ezagent.Behavior.Pty}
    ]
  end

  @impl Ezagent.Plugin
  def template_classes, do: [Ezagent.PluginEcho.Template.EchoAgent]

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "echo",
        # A3 — echo moves onto the unified `Ezagent.Entity.Agent` Kind
        # (mirroring curl PR-6+7). `Entity.Echo` is kept alive until A5
        # (deletion gate). The per-instance behavior SET threads
        # `echo_behaviors/0` so direct-create and template-create paths
        # both get the echo-specific behavior set (same pattern as curl's
        # `instance_behaviors: &AgentKind.curl_behaviors/0`).
        kind: Ezagent.Entity.Agent,
        template_class: Ezagent.PluginEcho.Template.EchoAgent,
        # A8 — register the `:in_process_sync` bridge adapter so that
        # `{Entity.Agent, :receive}` fan-out is routed to
        # `EzagentPluginEcho.BridgeAdapter.deliver/2` (which calls
        # `Behavior.Echo.handle_receive/2` in-process and fires the
        # "echo: <text>" `session.send` reply). Without this, the delivery
        # falls to the `:subprocess_ws` default → `:no_bridge` → silent drop.
        bridge_adapter: EzagentPluginEcho.BridgeAdapter,
        instance_behaviors: &Ezagent.Entity.Agent.echo_behaviors/0
      }
    ]
  end

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :flavor, flavor: "echo", label: "Echo Agents"}
  end

  @impl Ezagent.Plugin
  def children do
    [
      {DynamicSupervisor, name: EzagentPluginEcho.InstanceSupervisor, strategy: :one_for_one}
    ]
  end

  @doc """
  Phase 3 post-register hook — seed the default Echo agent (PR-5
  codex HIGH-2).

  `Ezagent.Plugin.boot/1` calls this AFTER Phase-2 `publish/1` has
  registered `agent_flavors/0`, so `Ezagent.AgentFlavorRegistry`
  already maps the `"echo"` flavor → `Ezagent.Entity.Agent` (A5: `Entity.Echo`
  deleted). The seed
  spawns through `Ezagent.SpawnRegistry.spawn/1` — the standard
  `entity://` resolver path — and this plugin's dep on
  `ezagent_domain_session` guarantees the `entity://` dispatcher is
  published before this runs.

  Idempotent: `SpawnRegistry.spawn/1` returns the existing pid for an
  already-alive Kind (snapshot rehydration), and treats
  `{:already_started, _}` as `{:ok, _}`. A genuine failure is logged,
  not raised — `after_boot/0` must not abort the plugin's boot — but
  with the dep + Phase ordering above this path is no longer racy.
  """
  @impl Ezagent.Plugin
  def after_boot do
    default_uri = default_uri()
    :ok = Ezagent.AgentFlavorAttributes.put(default_uri, "echo")

    # A7 fix — use Kind.spawn/2 with explicit echo_behaviors() so the
    # default echo agent's instance set includes Behavior.Echo (:say +
    # :receive handler). SpawnRegistry.spawn/1 (the prior call) routes
    # through spawn_agent/1 which passes only %{uri: uri} — omitting
    # :behaviors — so the Agent resolves nil_capture_behavior_set/0
    # (base behaviors only, no Echo), and any :say dispatch returns
    # {:error, :behavior_not_in_instance_set}. This is the same fix
    # already applied to EchoAgent.Template.ensure_agent_kind/1 (A4).
    init_args = %{
      uri: default_uri,
      behaviors: Ezagent.Entity.Agent.echo_behaviors()
    }

    case Ezagent.Kind.spawn(Ezagent.Entity.Agent, init_args) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        # Idempotent — a previous boot left the default agent alive.
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "EzagentPluginEcho.after_boot/0: default echo agent spawn failed " <>
            "(#{inspect(reason)}); F1 echo round-trip tests will fail until the " <>
            "default echo agent is available"
        )

        :ok
    end
  end

  # --- public API -----------------------------------------------------

  @doc """
  URI of the default Echo instance — seeded by `after_boot/0`
  (PR-5 codex HIGH-2, see moduledoc).
  """
  def default_uri, do: Ezagent.URI.agent(:system, :echo_default)
end
