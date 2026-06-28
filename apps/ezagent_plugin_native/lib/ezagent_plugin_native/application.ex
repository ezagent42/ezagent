defmodule EzagentPluginNative.Application do
  @moduledoc """
  Native plugin OTP application — the `Ezagent.Plugin` contract module
  (role-foundation RF-8).

  ## Plugin authoring contract

  Per the plugin authoring contract SPEC
  (`docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`) this
  module `use`s **both** `Application` (OTP plumbing) and `Ezagent.Plugin`
  (the declarative contract). `start/2` collapses to
  `Ezagent.Plugin.boot(__MODULE__)`; the framework's two-phase `boot/1` reads
  the declaration callbacks below and performs every `*Registry` call — the
  plugin author never touches a registry API.

  ## What this plugin declares — and deliberately does NOT

  The `native` flavor is the generic, NO-engine / NO-sidecar / NO-bridge host
  for ROLE agents (kanban-manager and friends). "Adding a flavor = adding a
  plugin", so native is its own plugin even though it owns no engine.

  - `agent_flavors/0` — flavor `"native"` → `{Ezagent.Entity.Agent,
    Ezagent.PluginNative.Template}`, **plus a `:cap_policy`** for native's
    CapMint policy (see below). The `kind` is the UNIFIED `Entity.Agent` (the
    generic host, like `curl`), NOT a dedicated Kind: native must spawn an
    `Entity.Agent` with no external engine.
  - It declares **NO `behaviors/0`**, **NO `bridge_adapter`**, and **NO
    `instance_behaviors` thunk**. native declares NOTHING role-specific: a
    native instance spawned with no explicit `:behaviors` captures
    `Entity.Agent.nil_capture_behavior_set/0` (the base Agent set), and the
    ROLE supplies any extra behaviors per-instance via the recipe at create
    (RF-5a / RF-1). Omitting `instance_behaviors` (vs `fn -> [] end`) keeps
    native out of `Entity.Agent.behaviors/0`'s registry union entirely, and
    guarantees a native instance never inherits a sibling flavor's behaviors
    (e.g. curl's `Behavior.CurlAgent`).
  - `template_classes/0` — the minimal `native.agent` Template Class
    (`config_schema/0 → []`; no flavor config — the role supplies everything).
  - `config_surface/0` — the `:flavor` surface (the `/plugins` icon routes to
    native's agent surface).
  - `children/0` — a per-plugin `DynamicSupervisor` (house style). native
    Kinds spawn under the unified Agent Kind's supervisor
    (`Entity.Agent.supervisor/0`), so this is retained only for any future
    per-instance child this plugin might own.

  ## CapMint cap-policy (RF-8)

  `Ezagent.Agent.Recipe.CapMint.mint/3` takes an INJECTED, fail-closed policy
  predicate; CapMint is the flavor-neutral minting mechanism, the per-flavor
  policy is data. native's policy is declared on the flavor decl as
  `:cap_policy` (`&EzagentPluginNative.CapPolicy.for_recipe/1`) and lives in
  the plugin (NOT core — core must not name a flavor). It grants exactly the
  recipe's `requested_caps` and nothing else (fail-closed default). RF-5a's
  create wiring reads the flavor's `:cap_policy` from
  `Ezagent.AgentFlavorRegistry` and passes the per-recipe predicate to
  `CapMint.mint/3`; this plugin only DECLARES the policy.
  """

  use Application
  use Ezagent.Plugin

  alias Ezagent.Entity.Agent, as: AgentKind
  alias Ezagent.PluginNative.Template, as: NativeTemplate

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract ---------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "native",
      name: "Native",
      description:
        "Generic no-engine host for role agents — the `native` flavor " <>
          "(role-foundation RF-8).",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def template_classes, do: [NativeTemplate]

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "native",
        # The generic, no-sidecar host — the UNIFIED Agent Kind. native
        # declares NO `instance_behaviors`: a native instance captures the
        # base Agent set, and the ROLE adds behaviors per-instance (RF-5a).
        kind: AgentKind,
        template_class: NativeTemplate,
        # RF-8 — native's fail-closed CapMint policy. RF-5a reads this from
        # the flavor registry and passes `cap_policy.(recipe.requested_caps)`
        # to `Ezagent.Agent.Recipe.CapMint.mint/3`. Grants exactly the recipe's
        # requested caps; rejects everything else.
        cap_policy: &EzagentPluginNative.CapPolicy.for_recipe/1
      }
    ]
  end

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :flavor, flavor: "native", label: "Native Agents"}
  end

  @impl Ezagent.Plugin
  def children do
    [
      {DynamicSupervisor, name: EzagentPluginNative.InstanceSupervisor, strategy: :one_for_one}
    ]
  end
end
