defmodule Mix.Tasks.Ezagent.Arch.Scan do
  @shortdoc "Scan architecture fitness-function counters"

  @moduledoc """
  > **Architecture deepening Phase 2 — Category A dev-loop tool.**
  > Like `mix ezagent.check_invariants`, this is a source-tree scan
  > that runs without relying on the runtime BEAM. It intentionally
  > stays under `mix ezagent.arch.*`.

  Prints each architecture fitness function, the measured count, the
  baseline cap from `test/architecture/arch_baseline_manifest.exs`, and
  PASS/FAIL. Architecture tests reuse `measure/0` and assert the
  green-at-baseline ratchet: measured count <= manifest cap.

  Suppression: a source line containing `# arch-allow:` is excluded from
  line-based counters. Manifest cap raises must carry
  `# arch-cap-bump: <reason>` and are checked by the ExUnit suite.
  """
  use Mix.Task

  @scanner_path "apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex"
  @manifest_path "apps/ezagent_core/test/architecture/arch_baseline_manifest.exs"

  @def_count_files %{
    def_count_cc_agent: "apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex",
    def_count_orchestrator_tools: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex",
    def_count_session_creator:
      "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex",
    def_count_capability: "apps/ezagent_core/lib/ezagent/capability.ex"
  }

  # Phase-4 CBAC signing: these are the complete verify/verified-set ingress
  # chain. A bad signature is an ordinary deny (`false`), but missing key
  # material or a crypto failure is an operational failure and must raise. Keep
  # this scanner deliberately bounded to that chain so unrelated error handling
  # cannot mask or inflate the security invariant.
  @cap_verify_fail_loud_targets %{
    "apps/ezagent_core/lib/ezagent/cap.ex" => [
      verified_set: 2
    ],
    "apps/ezagent_core/lib/ezagent/cap/authority.ex" => [
      verify: 3,
      verify_current: 2
    ],
    "apps/ezagent_core/lib/ezagent/cap/verifier.ex" => [
      authorize: 5,
      verify_cap: 5,
      valid_for?: 3
    ],
    "apps/ezagent_domain_identity/lib/ezagent/identity.ex" => [
      verified_cap_list: 2,
      verified_cap_set: 2
    ],
    "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex" => [
      create: 1,
      activate: 2,
      store_verified_cap: 3
    ],
    "apps/ezagent_domain_identity/lib/ezagent/identity/recipe_cap_binding.ex" => [
      validate_artifact: 4
    ],
    "apps/ezagent_actor/lib/ezagent/kind/snapshot.ex" => [
      verify_snapshot_caps: 2,
      put_verified_snapshot_caps: 4
    ]
  }

  @cap_verify_fail_loud_function_keys @cap_verify_fail_loud_targets
                                      |> Map.values()
                                      |> List.flatten()
                                      |> MapSet.new()

  @template_class_files [
    "apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex",
    "apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex"
  ]

  @spawn_registry_sanctioned_files [
    "apps/ezagent_actor/lib/ezagent/spawn_registry.ex",
    # #95 — the owner-gated plugin runtime facade. THE sanctioned chokepoint
    # plugins call instead of touching SpawnRegistry directly; it delegates to the
    # already-owner-gated SpawnRegistry.spawn[_detailed]. As plugins migrate onto
    # it (PR-2+), the off-chokepoint count drops; this keeps the facade itself
    # on-chokepoint.
    "apps/ezagent_actor/lib/ezagent/local_runtime.ex",
    "apps/ezagent_actor/lib/ezagent/invocation.ex",
    "apps/ezagent_core/lib/ezagent_core/application.ex",
    "apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex",
    "apps/ezagent_domain_session/lib/ezagent/entity/session.ex",
    "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex",
    "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex",
    # Transport #53 Decision C (codex C-rC-P1) — the orchestrator MCP transport's
    # durable-rebuild path forces the Session Kind to rehydrate (through the
    # SANCTIONED SpawnRegistry chokepoint) on a bridge reconnect after a BEAM
    # restart, so the session-domain `session` spawn fn restarts the
    # per-orchestrator `SessionManager` executor. cc spawns nothing itself; it
    # references the session it already routes to via the chokepoint.
    "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex"
    # (#99 C) protocol_api conversation_registry + openai_chat_plug migrated OFF
    # SpawnRegistry onto the owner-gated `Ezagent.LocalRuntime` facade — they no
    # longer call `SpawnRegistry.spawn`, so they leave both the spawn-set and this
    # sanctioned allowlist (the facade itself — local_runtime.ex above — is the
    # on-chokepoint delegate).
  ]

  # socialware-seed-path gate (2026-07-07, deploy-seed SPEC §5b). The ONLY
  # sanctioned `ConfigGovernance.Socialware.publish_or_upgrade(` call site is the
  # framework's generic governed import lane (`ManifestYaml.import/2`) — the
  # chokepoint the deployment-directory seed scan (`ManifestSeed.scan_all!`)
  # flows through. Every OTHER `publish_or_upgrade(` call is a plugin/socialware
  # self-publish at boot (the retired `Demo.publish` shape — hello/kanban/
  # dealscout), which must migrate onto the deploy-seed lane. Plugin
  # self-publishers are NOT on this list, so they trip the gate.
  @socialware_publish_sanctioned_files [
    "apps/ezagent_domain_session/lib/ezagent/socialware/manifest_yaml.ex"
  ]

  @spawn_fresh_sanctioned [
    # PR-2 config-evolve — shifted +6 by adding `Ezagent.ActionSet.ConfigEvolve`
    # (+ its comment block) to `Agent.behaviors/0`; same sanctioned defs/call.
    # PR-6 (im/session/agent decomposition) — shifted +41/+40 by splitting
    # `Agent.behaviors/0` into `base_behaviors/0` + `curl_behaviors/0` +
    # `nil_capture_behavior_set/0` (the curl flavor fold); SAME sanctioned
    # `spawn/4` shim + `spawn_fresh/4` def + its single call site, lower lines.
    # PR-6+7 (curl-as-flavor forward-only) — shifted +1 by the moduledoc comment
    # rewording on `Agent.behaviors/0` (standalone curl Kind now DELETED). SAME
    # sanctioned defs/call, one line lower.
    # PR-A (#53 agent→session decouple) — shifted -1 by removing
    # `Ezagent.ActionSet.Session` from `Agent.base_behaviors/0`. SAME sanctioned
    # `spawn_fresh/4` call site + `@spec` + `def`, one line higher.
    # PR-9a (#53 physical split) — `entity/agent.ex` relocated VERBATIM to the
    # new `ezagent_domain_agent` app (module name FROZEN); content unchanged so
    # the line anchors hold, only the app-dir path prefix changed.
    # cc-headless sidecar insertion shifted the same sanctioned shim/spec/def
    # anchors lower; the spawn-fresh ownership boundary is unchanged.
    # CR-governance (SPEC 2026-06-26 rev 3) — shifted +6 by adding
    # `Ezagent.ActionSet.ConfigGovernance` (+ its comment block) to
    # `Agent.base_behaviors/0`, the same kind of insertion config-evolve made.
    # SAME sanctioned `spawn_fresh/4` call site + `@spec` + `def`, six lines
    # lower; the spawn-fresh ownership boundary is unchanged.
    # #161 A1.1 — inserting `Agent.list_in_workspace/1` (the member-cap reconcile
    # candidate enumerator) near the top of the module shifted the same three
    # sanctioned anchors down by +46 (254→300 call site, 293→339 `@spec`,
    # 295→341 `def spawn_fresh/4`). SAME spawn-fresh ownership boundary; A1 added
    # no new spawn_fresh caller, it only pushed the frozen surface lower.
    {"apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex", 310},
    {"apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex", 349},
    {"apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex", 351},
    # PR-3S — `spawn_fresh_member/8` (def) + its single call site moved VERBATIM
    # from `Orchestrator.Tools` to `Orchestrator.Tools.MemberTemplate` along with
    # the `update_member_template` regenerate cluster (gt_1000 4→3 extraction).
    # PR-8 (transport #53) — the MCP TRANSPORT relocated im → cc, but the tool
    # OPERATIONS (`Orchestrator.Tools` + `Orchestrator.Tools.MemberTemplate`)
    # STAY in the session domain (O-4); paths restored to im.
    {"apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/member_template.ex", 190},
    {"apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/member_template.ex", 223}
  ]

  @all_slices_sanctioned [
    # P1 (socialware substrate) — shifted 182→183 by the `instance_set_gate`
    # insertion into `handle_dispatch`'s `with` chain (runtime.ex E9). Same
    # sanctioned `:all_slices` comment, one line lower.
    # P2.5c — shifted 183→180: net comment trim in `handle_dispatch` (the
    # `deferred` 4-tuple bind added, but verbose @type/comment blocks
    # condensed to keep runtime.ex under the gt_1000 LOC gate).
    # P5-1b — shifted 180→168: condensed the PR-N3 cursor comment to absorb the
    # `instance_set_gate` denial-telemetry caller/target enrichment (audit
    # handler no longer detaches on a per-instance denial) under the LOC gate.
    # RF-1 — shifted 168→169: the `lookup_behavior` call became a 2-line
    # `Ezagent.Kind.BehaviorSet.resolve_action/3` call in `handle_dispatch`'s
    # `with` chain (per-instance action→behavior resolution, role-foundation).
    # Reputation-receipt (facts layer) — shifted 169→157: net -12 in
    # `handle_dispatch` — the central-verifier bind + step-10.5
    # central-verifier bind + receipt call were MORE than offset by condensing the ctx-enrichment /
    # slice-change / sibling-slice comment blocks (runtime.ex held ≤1000 LOC gate;
    # receipt logic itself lives in `Ezagent.Kind.Runtime.Receipt`).
    {"apps/ezagent_actor/lib/ezagent/kind/runtime.ex", 179},
    # py-agent P2 (echo→py teaching-example re-home) — shifted 454→453: the
    # the echo worked-example moduledoc line was condensed to a
    # `Ezagent.ActionSet.PyAgent` reference (net -1 line ABOVE this comment).
    {"apps/ezagent_actor/lib/ezagent/behavior.ex", 453}
    # PR-4 (agent-owned config-evolve) — shifted 271→272 when the #607
    # `system://agent-internal` Sandbox:read drop replaced the old #607 comment
    # block with a (one-line-longer) note above this ApiKeys-flip comment. Same
    # sanctioned `ctx[:all_slices][:api_keys]` mention, one line lower.
    # Decision #154 (no-unowned, 2026-06-16) — shifted 272→281: the
    # `system://agent-internal` `cap(:user, IdentityAdmin, :grant_cap)` drop added
    # a 9-line vestigial-cap-drop rationale block ABOVE this ApiKeys-flip comment.
    # Decision #154 PR-2 (template-materialize → non-minter, 2026-06-17) — shifted
    # 281→284: dropping template-materialize's grant-minter caps replaced the
    # entry's cap list with a 3-line-longer rationale block ABOVE this comment.
    # no-unowned-caps PR-1 (per-session participation, 2026-06-17) — shifted
    # 284→290: deleting the `feishu-binding-policy` Catalog entry (the last
    # grant-minter) ABOVE this comment net +6 lines (replaced a 15-line entry
    # with a 9-line deletion-rationale block). Same sanctioned
    # `ctx[:all_slices][:api_keys]` ApiKeys-flip comment, six lines lower.
    # System-principal elimination (worker-publish, 2026-06-19) — shifted
    # 290→293: deleting the `worker-publish` Catalog entry + its two Behavior
    # aliases ABOVE this comment net +3 lines.
    # System-principal elimination (adapter-install + boot-reconciler dead-delete,
    # 2026-06-19) — shifted 293→292: the two dead entries collapsed to shorter
    # deletion-rationale comments, net -1 (incl. the ExternalMirror alias→comment swap).
    # System-principal elimination (agent-internal, 2026-06-19) — catalog entry
    # REMOVED. The sanctioned `ctx[:all_slices][:api_keys]` ApiKeys-flip comment
    # lived INSIDE the deleted `system://agent-internal` entry, so its `:all_slices`
    # mention is gone with the entry — the catalog sanctioned line is dropped (it
    # no longer points at an `:all_slices` hit). The remaining sanctioned hits
    # (runtime.ex, behavior.ex) are untouched.
  ]

  @runtime_file "apps/ezagent_actor/lib/ezagent/kind/runtime.ex"
  @measure_cache_key {__MODULE__, :measure}

  # FF-1 — cross_file_duplicate_fn_groups.
  #
  # A function body is NOT counted as a fork when its `{name, arity}` is a
  # framework behaviour callback AND the *enclosing module* actually declares the
  # owning behaviour (via `use` / `@behaviour`). An identical callback body across
  # two modules that both `use GenServer` is a contract obligation, not a
  # copy-paste fork. Crucially the exemption is behaviour-SCOPED (codex r1 HIGH):
  # a plain production helper coincidentally named `update`/`render`/`init`/
  # `changeset` in a module that does NOT use the owning behaviour is still
  # counted, so a new fork cannot hide behind a callback-shaped name.
  #
  # `@dup_callback_owners` maps an owner's LAST module segment (matched exactly,
  # not as a substring — codex r2: a `use My.FancyComponents` must NOT match the
  # `Component` owner) against the `{name, arity}` callbacks that behaviour owns.
  # The marker must come from a `use X` / `@behaviour X` declared in the same
  # enclosing module.
  @dup_callback_owners %{
    "GenServer" => [
      {:init, 1},
      {:terminate, 2},
      {:handle_call, 3},
      {:handle_cast, 2},
      {:handle_info, 2},
      {:handle_continue, 2},
      {:code_change, 3},
      {:format_status, 1},
      {:format_status, 2}
    ],
    "Supervisor" => [{:init, 1}],
    "Application" => [{:start, 2}, {:stop, 1}],
    "LiveView" => [
      {:mount, 3},
      {:render, 1},
      {:handle_event, 3},
      {:handle_params, 3},
      {:handle_info, 2},
      {:terminate, 2}
    ],
    "LiveComponent" => [{:mount, 1}, {:render, 1}, {:update, 2}, {:handle_event, 3}],
    "Component" => [{:render, 1}],
    "Channel" => [{:join, 3}, {:handle_in, 3}, {:handle_info, 2}, {:terminate, 2}],
    "Schema" => [{:changeset, 2}],
    "Ecto" => [{:changeset, 2}],
    "Lifecycle" => [{:create, 1}, {:activate, 2}, {:deactivate, 2}, {:destroy, 1}],
    "ActionSet" => [{:required_caps, 0}],
    # `use Mix.Task` obligates `run/1` (the `@impl Mix.Task` callback). One-shot
    # snapshot-migration tasks sharing the SAME thin `run/1` dispatch skeleton
    # (parse switches → `cond` → `Ezagent.Migration.RepoOnly.run/1`) is a
    # callback contract, not a copy-paste fork — exempt it, scoped to modules
    # that actually `use Mix.Task`. (Originally closed by PR-6+7 curl-as-flavor
    # for `ezagent.curl.migrate` + `ezagent.session.migrate_slice`; the curl
    # task was deleted with the retired curl_agent Kind migration machinery —
    # chore/retire-dead-kind-migrations — but the general `use Mix.Task` exemption
    # still applies to every task in this shape, e.g. `ezagent.session.migrate_slice`.)
    "Task" => [{:run, 1}]
  }

  # `{name, arity}` exempt in EVERY module — universal OTP child-spec boilerplate
  # that is mechanically identical by design and not behaviour-gated.
  @dup_always_exempt MapSet.new([{:child_spec, 1}, {:start_link, 1}])

  # FF-1 — only bodies at least this many normalized chars are considered, so a
  # one-liner shared by coincidence (`do: :ok`) is not a "fork".
  @dup_fn_min_body_chars 120

  # FF-4 — the `/cc_socket` deprecation shim modules (promoted to the
  # `ezagent_domain_agent_bridge` domain). A non-`agent_bridge`/non-test lib file
  # that still references one — fully-qualified, via a grouped `alias` (codex r1
  # MEDIUM), or a renamed `alias ..., as: X` — is a caller of the shim. Cleanup-3
  # migrates these to the `Ezagent.AgentBridge.*` modules + deletes the shims,
  # ratcheting this to 0.
  @cc_bridge_shim_modules [
    [:EzagentPluginCc, :BridgeRegistry],
    [:EzagentPluginCc, :Socket],
    [:EzagentPluginCc, :Channel],
    [:EzagentPluginCc, :TokenStore]
  ]

  # The shim DEFINITION files themselves — a shim module referencing its own name
  # (its `defmodule`) is not a "caller".
  @cc_bridge_shim_files [
    "apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/bridge_registry.ex",
    "apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/socket.ex",
    "apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/channel.ex",
    "apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/token_store.ex"
  ]

  # domain-only-Kinds gate — Kinds are a domain concern. A concrete Kind is a
  # module declaring `@behaviour Ezagent.Kind` EXACTLY (NOT `Ezagent.Kind.Template`,
  # which is a blueprint/Template Class plugins legitimately define; the AST matcher
  # resolves aliases so `alias Ezagent.Kind` + `@behaviour Kind` is caught too).
  # Plugin apps
  # (`apps/ezagent_plugin_*`) compose via Template/Behavior/View; a plugin defining
  # a concrete Kind is architectural debt — the concept must move to a domain app
  # (or be promoted to domain). Counts plugin-app concrete-Kind files MINUS this
  # sanctioned allowlist, which is a ratchet that shrinks to empty as the debt is
  # retired. `plugin_defined_kinds` (target-zero) trips on any NEW plugin Kind or
  # any re-add of an allowlisted concept elsewhere in a plugin.
  #
  # Original snapshot named three offenders; two had already been retired on
  # origin/main (the ratchet advanced past the snapshot), so only one remains:
  #   - echo    → RETIRED: `apps/ezagent_plugin_echo` deleted entirely.
  #   - np/py   → RETIRED: folded to `apps/ezagent_plugin_py/lib/ezagent/template/
  #               py_agent.ex`, now an `Ezagent.Kind.Template` (correctly NOT a Kind).
  #   - hello   → PENDING: to be promoted to a socialware. Must reach 0.
  @plugin_defined_kind_allowlist [
    "apps/ezagent_plugin_hello/lib/ezagent/entity/hello_builder.ex"
  ]

  # Namespace-dot convention gate (2026-07-08, GLOSSARY Decision #161 follow-up).
  # A module that lives inside an existing parent namespace must use the DOTTED
  # child form (`Ezagent.Agent.RecipeResolver`), never parent-name concatenation
  # (`Ezagent.AgentRecipeResolver`). `concatenated_namespace_modules` flags a
  # SINGLE-SEGMENT `defmodule Ezagent.XyzAbc` when `Ezagent.Xyz` is a namespace
  # that has DOTTED CHILDREN in the SAME app (so `XyzAbc` is just parent+child
  # glued and should be `Xyz.Abc`), MINUS this sanctioned allowlist. Suppression
  # for this gate is by MODULE NAME here (not a line-based `# arch-allow:`) — you
  # sanction a compound by naming it, since the offence is the name itself.
  #
  # Every entry is a genuine single-concept compound, a namespace ROOT with its
  # own dotted children, or a conventional role-suffix (Registry/Store/Supervisor)
  # / genuinely-ambiguous name kept by convention — NOT a glued parent+child that
  # should be dotted. The two real offenders (`AgentRecipeResolver`,
  # `AgentRecipeAttributes`) were renamed to `Ezagent.Agent.Recipe*` (they join
  # the existing dotted `Ezagent.Agent.Recipe*` cluster), so cap is 0.
  @concatenated_namespace_allowlist [
    # EntityCaps — the locked storage-facade name and namespace ROOT for its
    # user/agent store adapters; it is not Entity.Caps parent-child glue.
    "Ezagent.EntityCaps",
    # AgentFlavor* — "agent flavor" is itself the unit (a flavor OF agent); the
    # flavor cluster is deliberately glued (Registry/Attributes/Resolver), NOT
    # dotted under Ezagent.Agent.
    "Ezagent.AgentFlavorRegistry",
    "Ezagent.AgentFlavorAttributes",
    "Ezagent.AgentFlavorResolver",
    # AgentPassiveAttributes — the `passive` launch-attribute table; its own
    # moduledoc declares it "exactly parallel to AgentFlavorAttributes", and there
    # is NO dotted `Agent.Passive*` sibling cluster (unlike `Agent.Recipe*`).
    # Reviewed & sanctioned 2026-07-09 (jjkysy): deliberate mirror of the
    # sanctioned AgentFlavor* glued cluster — renaming it alone would break the
    # flavor/passive symmetry; renaming both reopens an already-sanctioned call.
    "Ezagent.AgentPassiveAttributes",
    # AgentBridge — the ezagent_domain_agent_bridge app's OWN root namespace
    # (Ezagent.AgentBridge.*), a domain concept; that app has no Ezagent.Agent
    # namespace, so the scan never flags it. Documentary entry (task-requested).
    "Ezagent.AgentBridge",
    # AgentLineage — single-concept "lineage of an agent" value in ezagent_core.
    "Ezagent.AgentLineage",
    # AgentManifest — the agent-manifest schema; a namespace ROOT with its own
    # child (Ezagent.AgentManifest.Tools). One concept, distinct from the
    # ezagent_core Ezagent.Agent recipe/materialize cluster.
    "Ezagent.AgentManifest",
    # Registry-OF-X role-suffix (conventional single concept; several are
    # namespace roots with their own children, e.g. CapabilityRegistry.Defaults).
    "Ezagent.CapabilityRegistry",
    "Ezagent.KindRegistry",
    "Ezagent.PluginRegistry",
    "Ezagent.PluginAssetRegistry",
    "Ezagent.RoutingRegistry",
    # KindSupervisor — conventional OTP "supervisor OF Kinds" role-suffix name.
    "Ezagent.KindSupervisor",
    # Store-OF-X role-suffix (conventional single concept).
    "Ezagent.MessageStore",
    "Ezagent.SnapshotStore",
    # PluginPackage — one concept (a plugin package); namespace root with its own
    # children (Ezagent.PluginPackage.*).
    "Ezagent.PluginPackage",
    # RuntimeIdentity — "the identity of the runtime"; ambiguous vs Runtime.Identity
    # but no dotted sibling cluster. Reviewed & sanctioned 2026-07-09 (jjkysy):
    # the Ezagent.Runtime.* siblings are the OS-subprocess pipeline
    # (line_buffer/os_process/orphan_reaper/pid_file) — an unrelated concept;
    # `Runtime.Identity` would wrongly imply membership in that cluster.
    "Ezagent.RuntimeIdentity",
    # SystemPrincipal — a domain concept (a principal that is a system actor);
    # namespace root with its own child (Ezagent.SystemPrincipal.Catalog),
    # distinct from the Ezagent.System.* cluster.
    "Ezagent.SystemPrincipal",
    # EntityPresenter — "presenter for entities"; ambiguous vs Entity.Presenter
    # but no dotted sibling cluster. Reviewed & sanctioned 2026-07-09 (jjkysy):
    # X-of-Y role-suffix convention (same family as KindRegistry/MessageStore/
    # KindSupervisor above); widely referenced across render layers — rename
    # yields the least value of the three surveyed. Closest call: revisit only
    # if an Entity.Presenter.* child cluster ever emerges.
    "Ezagent.EntityPresenter"
  ]

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("ezagent.arch.scan — architecture fitness functions")

    manifest = manifest()

    results =
      measure()
      |> Enum.map(fn {name, count} ->
        cap = Map.fetch!(manifest, name)
        status = if count <= cap, do: "PASS", else: "FAIL"
        {status, name, count, cap}
      end)

    Enum.each(results, fn {status, name, count, cap} ->
      Mix.shell().info("  #{status} #{name}: count=#{count} cap=#{cap}")
    end)

    failures = Enum.reject(results, fn {status, _name, _count, _cap} -> status == "PASS" end)

    if failures == [] do
      :ok
    else
      Mix.raise("ezagent.arch.scan: #{length(failures)} architecture counter(s) above cap")
    end
  end

  @doc false
  def count(name) when is_atom(name) do
    measure()
    |> Map.new()
    |> Map.fetch!(name)
  end

  @doc false
  def measure do
    case :persistent_term.get(@measure_cache_key, :missing) do
      :missing ->
        results = do_measure()
        :persistent_term.put(@measure_cache_key, results)
        results

      results ->
        results
    end
  end

  defp do_measure do
    oversized = oversized_modules()
    # AST-based (2026-07 batch-1): resolves `alias Ezagent.SpawnRegistry, as: X`
    # and is immune to moduledoc/comment/string mentions + function-capture
    # (`&Mod.fun/arity`) non-calls that the old per-line grep over-counted. Emits
    # `{file, line, :ast}` triples so `unique_files/1` + the off-chokepoint reject
    # keep working unchanged.
    spawn_hits = spawn_registry_call_hits()
    create_session_hits = create_session_call_hits()
    spawn_fresh_hits = grep(~r/spawn_fresh(?:_member)?\(/, skip_comment_lines?: true)
    all_slices_hits = grep(~r/:all_slices/)
    set_effect_hits = grep(~r/\{:set,\s*:[a-z_]+,/)
    flavor_refs_in_core = grep_core(~r/AgentFlavor(?:Registry|Attributes|Resolver)/)

    [
      oversized_modules_gt_1500: count_oversized(oversized, 1500),
      oversized_modules_gt_1000: count_oversized(oversized, 1000),
      def_count_cc_agent: def_count(:def_count_cc_agent),
      def_count_orchestrator_tools: def_count(:def_count_orchestrator_tools),
      def_count_session_creator: def_count(:def_count_session_creator),
      def_count_capability: def_count(:def_count_capability),
      cap_verify_rescue_to_false: cap_verify_rescue_to_false(),
      spawn_registry_call_sites: length(spawn_hits),
      spawn_registry_modules: spawn_hits |> unique_files() |> length(),
      spawn_registry_off_chokepoint_modules:
        spawn_hits
        |> unique_files()
        |> Enum.reject(&(&1 in @spawn_registry_sanctioned_files))
        |> length(),
      create_session_call_sites: length(create_session_hits),
      create_session_modules: create_session_hits |> unique_files() |> length(),
      duplicated_resolve_template_class: duplicated_resolve_template_class(),
      # FF-1: generalizes duplicated_resolve_template_class (which counts ONE
      # known forked function by name) to the whole tree — every group of ≥2 lib
      # files sharing a byte-identical (whitespace-normalized) function body.
      # `duplicated_resolve_template_class` stays as the targeted ratchet for that
      # specific fork; FF-1 is the broad fitness function for fork accretion.
      cross_file_duplicate_fn_groups: cross_file_duplicate_fn_groups(),
      cc_bridge_shim_callers: cc_bridge_shim_callers(),
      plugin_defined_kinds: plugin_defined_kinds(),
      cc_codex_template_class_combined_loc:
        @template_class_files |> Enum.map(&line_count/1) |> Enum.sum(),
      raw_home_path_outside_core: raw_home_path_outside_core(),
      path_expand_home: length(grep(~r/Path\.expand\("~/)),
      spawn_fresh_audit_references: length(spawn_fresh_hits),
      spawn_fresh_unsanctioned: unsanctioned_count(spawn_fresh_hits, @spawn_fresh_sanctioned),
      all_slices_occurrences: length(all_slices_hits),
      all_slices_unsanctioned: unsanctioned_count(all_slices_hits, @all_slices_sanctioned),
      set_effect_sites: length(set_effect_hits),
      cross_slice_set_violations: cross_slice_set_violations(set_effect_hits),
      missing_cap_check_mutating_actions: missing_cap_check_mutating_actions(),
      kind_runtime_ordering_violations: kind_runtime_ordering_violations(),
      kind_runtime_reentry_violations: kind_runtime_reentry_violations(),
      no_flavor_refs_in_core: length(flavor_refs_in_core),
      cold_restart_respawn_round_trip_drift: cold_restart_respawn_round_trip_drift(),
      raw_port_spawn_executable: raw_port_spawn_executable(),
      resource_kind_as_genserver: resource_kind_as_genserver(),
      hardcoded_deploy_domain_hosts: hardcoded_deploy_domain_hosts(),
      socialware_priv_manifest_files: socialware_priv_manifest_files(),
      socialware_self_publish_unsanctioned: socialware_self_publish_unsanctioned(),
      concatenated_namespace_modules: concatenated_namespace_modules(),
      no_hardcoded_seed_principal: no_hardcoded_seed_principal()
    ]
  end

  # Phase-4 signing fail-loud gate. This searches only the exact verification
  # path above for a `try ... rescue ... -> false` escape hatch. `false` remains
  # correct for a normal signature denial, so the predicate is intentionally
  # scoped to a rescue clause rather than every false-returning branch.
  defp cap_verify_rescue_to_false do
    Enum.reduce(@cap_verify_fail_loud_targets, 0, fn {file, function_keys}, total ->
      case Code.string_to_quoted(read!(file)) do
        {:ok, ast} -> total + count_cap_verify_rescue_to_false(ast, MapSet.new(function_keys))
        {:error, _} -> total
      end
    end)
  end

  @doc false
  @spec count_cap_verify_rescue_to_false_in_source(String.t()) :: non_neg_integer()
  def count_cap_verify_rescue_to_false_in_source(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        count_cap_verify_rescue_to_false(ast, @cap_verify_fail_loud_function_keys)

      {:error, _} ->
        0
    end
  end

  defp count_cap_verify_rescue_to_false(ast, function_keys) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn
        {definition, _meta, [head, [{:do, body} | _]]} = node, count
        when definition in [:def, :defp] ->
          if MapSet.member?(function_keys, fn_key(head)) and rescue_returns_false?(body) do
            {node, count + 1}
          else
            {node, count}
          end

        node, count ->
          {node, count}
      end)

    count
  end

  defp rescue_returns_false?(body) do
    {_body, found?} =
      Macro.prewalk(body, false, fn
        {:try, _meta, [clauses]} = node, found? when is_list(clauses) ->
          rescue_returns_false? =
            clauses
            |> Keyword.get(:rescue, [])
            |> List.wrap()
            |> Enum.any?(&rescue_clause_contains_false?/1)

          {node, found? or rescue_returns_false?}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  # Any `false` inside a rescue clause is a possible infra-failure deny. This
  # intentionally catches conditional and case branches as well as a direct
  # `rescue _ -> false`; normal verification denial is outside `rescue` and is
  # therefore unaffected.
  defp rescue_clause_contains_false?({:->, _meta, [_patterns, body]}),
    do: contains_false?(body)

  defp rescue_clause_contains_false?(_clause), do: false

  defp contains_false?(body) do
    {_body, found?} =
      Macro.prewalk(body, false, fn
        false, _found? -> {false, true}
        node, found? -> {node, found?}
      end)

    found?
  end

  # World host-scope config (2026-06-29) — deployment host literals belong in
  # config/runtime config, not production lib code. This catches the operator
  # console regression shape (`host: "world."`) and app/world deploy host strings
  # copied into libraries (`"app.ezagent.chat"`, `"https://world.ezagent.chat"`).
  # It intentionally does NOT flag ezagent.chat email addresses/domains; email is
  # a product identity, not an HTTP deployment host.
  @hardcoded_deploy_domain_regex ~r/host:\s*"world\."|"(?:https?:\/\/)?(?:app|world)\.ezagent\.chat(?:\/[^"]*)?"/

  defp hardcoded_deploy_domain_hosts do
    grep(@hardcoded_deploy_domain_regex, skip_comment_lines?: true)
    |> length()
  end

  @doc false
  @spec count_hardcoded_deploy_domain_hosts_in_source(String.t()) :: non_neg_integer()
  def count_hardcoded_deploy_domain_hosts_in_source(source) when is_binary(source) do
    source
    |> String.split("\n")
    |> Enum.count(fn line ->
      not String.contains?(line, "# arch-allow:") and
        not comment_line?(line) and
        Regex.match?(@hardcoded_deploy_domain_regex, line)
    end)
  end

  # no_hardcoded_seed_principal (2026-07-24, Allen) — socialware & seed
  # provisioning must create a user/workspace (or grant ownership) using an
  # EXISTING env-provided user identity, NEVER a principal baked into source.
  #
  # AST-based (mirror `resource_kind_as_genserver` / `socialware_self_publish`):
  # flags a call to a user/workspace-CREATE or owner-GRANT chokepoint whose
  # arguments carry a HARDCODED principal identity. The chokepoints are the two
  # provisioning creators (`Users.create` / `Workspace.create`) plus the named
  # `create_user` / `create_workspace` / `founder_join` / `grant_owner` verbs.
  # A "hardcoded principal" node (searched anywhere inside the call's args, so a
  # nested `%{created_by: …}` owner is covered) is one of:
  #
  #   * a string literal that is a principal URI (`entity://…` / `user://…`) or
  #     an email address,
  #   * `_.admin_uri()` / bare `admin_uri()` — the genesis-admin accessor, and
  #   * `_.URI.user(a, b)` where a AND b are compile-time literals (an inline
  #     `Ezagent.URI.user(:system, :admin)` construction).
  #
  # It deliberately does NOT flag the env/runtime-resolved good pattern
  # (`Workspace.create(ws, %{created_by: founder_uri})` or
  # `Users.create(Ezagent.URI.user(workspace, slug), …)` — the args are VARS,
  # not literals). The genesis bootstrap (`admin_uri = User.admin_uri()` then
  # `Users.create(admin_uri, …)`) passes a bare var, so it is NOT flagged — the
  # identity domain's boot provisioning is the bootstrap, not a socialware seed,
  # and forward protection still holds (a NEW inline hardcoded-principal create
  # trips the gate). `# arch-allow:` on the call line — or the line directly
  # above it, the format-canonical spot — suppresses one site.
  @seed_principal_grant_fns MapSet.new([
                              :create_user,
                              :create_workspace,
                              :founder_join,
                              :grant_owner
                            ])

  # entity/user principal URIs; email addresses. Workspace URIs are resources,
  # not principals, so they are intentionally excluded.
  @principal_uri_re ~r{^(entity|user)://}
  @principal_email_re ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  defp no_hardcoded_seed_principal do
    lib_files()
    |> Enum.map(fn file ->
      case Code.string_to_quoted(read!(file)) do
        {:ok, ast} ->
          count_hardcoded_seed_principal(ast, module_alias_map(ast), arch_allowed_lines(file))

        {:error, _} ->
          0
      end
    end)
    |> Enum.sum()
  end

  @doc """
  Testable entry for the `no_hardcoded_seed_principal` predicate: count the
  hardcoded-principal provisioning calls in a SOURCE STRING (positive/negative
  fixtures) so the gate test proves it flags a `Workspace.create(ws,
  %{created_by: User.admin_uri()})` / literal-URI create while a runtime-resolved
  `%{created_by: founder_uri}` (or `Ezagent.URI.user(workspace, slug)`) create is
  NOT flagged — without writing fixture files into the scanned lib tree.
  `# arch-allow:` on the offending line suppresses it, same as the real scan.
  """
  @spec count_hardcoded_seed_principal_in_source(String.t()) :: non_neg_integer()
  def count_hardcoded_seed_principal_in_source(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        count_hardcoded_seed_principal(
          ast,
          module_alias_map(ast),
          allowed_lines_in_source(source)
        )

      {:error, _} ->
        0
    end
  end

  defp count_hardcoded_seed_principal(ast, amap, allowed_lines) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, acc ->
        if seed_principal_violation?(node, amap, allowed_lines),
          do: {node, acc + 1},
          else: {node, acc}
      end)

    count
  end

  # A parenthesized remote call to a create/grant chokepoint whose args carry a
  # hardcoded principal identity, and whose site is not `# arch-allow:`ed.
  defp seed_principal_violation?(
         {{:., _dot_meta, [receiver, fun]}, meta, args},
         amap,
         allowed_lines
       )
       when is_atom(fun) and is_list(args) do
    not Keyword.get(meta, :no_parens, false) and
      not seed_principal_arch_allowed?(allowed_lines, Keyword.get(meta, :line, 0)) and
      provisioning_grant_call?(resolved_last_segment(receiver, amap), fun) and
      Enum.any?(args, &contains_hardcoded_principal?(&1, amap))
  end

  defp seed_principal_violation?(_node, _amap, _allowed_lines), do: false

  # A create/grant call is suppressed by a `# arch-allow:` on its own line OR on
  # the line directly above it. The line-above tolerance is required because
  # `mix format` canonicalizes a trailing `Foo.create(...) do # arch-allow: …`
  # comment onto the standalone line ABOVE the `case`, so pinning it to the exact
  # call line alone would silently un-suppress a sanctioned site after a format.
  defp seed_principal_arch_allowed?(allowed_lines, line) do
    MapSet.member?(allowed_lines, line) or MapSet.member?(allowed_lines, line - 1)
  end

  # `Users.create` / `Workspace.create` are the user/workspace creators; the
  # named verbs match on any receiver (they are specific enough to be the grant
  # chokepoint wherever they live).
  defp provisioning_grant_call?(:Users, :create), do: true
  defp provisioning_grant_call?(:Workspace, :create), do: true
  defp provisioning_grant_call?(_segment, fun), do: MapSet.member?(@seed_principal_grant_fns, fun)

  # True when the argument subtree contains ANY hardcoded-principal node (so a
  # nested `%{created_by: User.admin_uri()}` owner is caught).
  defp contains_hardcoded_principal?(arg, amap) do
    {_node, found?} =
      Macro.prewalk(arg, false, fn node, found? ->
        {node, found? or hardcoded_principal_node?(node, amap)}
      end)

    found?
  end

  # (a) principal URI / email string literal.
  defp hardcoded_principal_node?(bin, _amap) when is_binary(bin) do
    Regex.match?(@principal_uri_re, bin) or Regex.match?(@principal_email_re, bin)
  end

  # (b) `_.admin_uri()` (zero-arg remote call — the genesis-admin accessor).
  defp hardcoded_principal_node?({{:., _, [_receiver, :admin_uri]}, _, []}, _amap), do: true

  # (b') bare `admin_uri()` local CALL (args `[]`, not a bare var whose args are
  # `nil`) — a var *named* `admin_uri` is a binding reference, not a literal.
  defp hardcoded_principal_node?({:admin_uri, _, []}, _amap), do: true

  # (c) `_.URI.user(a, b)` with a AND b compile-time literals (atom or string).
  defp hardcoded_principal_node?({{:., _, [receiver, :user]}, _, [a, b]}, amap) do
    resolved_last_segment(receiver, amap) == :URI and literal_identity?(a) and
      literal_identity?(b)
  end

  defp hardcoded_principal_node?(_node, _amap), do: false

  defp literal_identity?(node), do: is_atom(node) or is_binary(node)

  # Socialware deploy-seed gate (2026-07-07, SPEC §5). Two shapes:
  #
  #   (a) `socialware_priv_manifest_files` — any `apps/*/priv/socialware/*/
  #       manifest.yaml` on disk. The plugin/domain-priv authoring lane is
  #       DEPRECATED (design §2): the canonical socialware home is the
  #       deployment directory (`$EZAGENT_HOME/<profile>/socialware/`), seeded
  #       from `ezagent_web/priv/socialware_seed/<name>/` via
  #       `Ezagent.Home.SocialwareSeed`. TARGET-ZERO — a manifest under
  #       `priv/socialware/` must move to the deploy-seed source. (NOTE the
  #       source dir name is `socialware_seed`, NOT `socialware`, so seed
  #       sources never trip this glob.) This shape uses a filesystem glob, not
  #       the `lib/**` scanner, because manifests are priv assets.
  #
  #   (b) `socialware_self_publish_unsanctioned` — non-framework
  #       `ConfigGovernance.Socialware.publish_or_upgrade(` call sites (the
  #       `Demo.publish` self-publish-at-boot shape). Only the framework import
  #       lane (`manifest_yaml.ex`, `@socialware_publish_sanctioned_files`) is
  #       allowed; every plugin self-publisher trips it. AST-based (parens-only
  #       remote calls), so the `@spec`/`def publish_or_upgrade` in
  #       `config_governance/socialware.ex` and doc mentions are NOT counted.
  defp socialware_priv_manifest_files do
    repo_root()
    |> Path.join("apps/*/priv/socialware/*/manifest.yaml")
    |> Path.wildcard()
    |> length()
  end

  defp socialware_self_publish_unsanctioned do
    ast_call_hits(fn _last_segment, fun -> fun == :publish_or_upgrade end)
    |> Enum.reject(fn {file, _line, _} -> file in @socialware_publish_sanctioned_files end)
    |> length()
  end

  @doc """
  Testable entry for `socialware_self_publish_unsanctioned`: count
  `publish_or_upgrade` remote-call sites in a SOURCE STRING (no sanctioned
  reject — the fixture asserts the raw AST hit count). Proves the gate matches a
  parenthesized `Governance.publish_or_upgrade(x, y)` call while a
  `&Mod.publish_or_upgrade/2` capture, the `@spec`/`def` head, and doc mentions
  are NOT counted.
  """
  @spec count_socialware_self_publish_in_source(String.t()) :: non_neg_integer()
  def count_socialware_self_publish_in_source(source) when is_binary(source) do
    count_calls_in_source(source, fn _last_segment, fun -> fun == :publish_or_upgrade end)
  end

  # kanban-as-role K5 (2026-06-25) — resource-only-files gate (cap 0). `resource://`
  # is "not a live Kind — pure data ref, filesystem on disk" (`uri-design.md`). The
  # abandoned Plan-B (#964) overloaded it with live spawnable Kinds
  # (`resource_kinds/0` plugin callback + a `ResourceKindRegistry` + a workspace
  # resource-dispatcher). kanban-as-role re-homes the board onto an `Entity.Agent`
  # (role × native), so `resource://` returns to pure-FS. This gate LOCKS that out
  # permanently (Plan-B never landed on main; this prevents its regression).
  #
  # AST-based (mirror `raw_port_spawn_executable`): walks every lib file's AST and
  # flags two shapes —
  #   (a) a plugin `resource_kinds/0` callback: `def resource_kinds(...)` (the
  #       Plan-B `@callback resource_kinds() :: [...]` plugin declaration), and
  #   (b) any call to a `ResourceKindRegistry`-style register:
  #       `(_.)*ResourceKindRegistry.register(...)`.
  # It must NOT flag the FS resolver's `resource_types/0` (the pure-FS resolver
  # callback) — that is the SANCTIONED resource shape. `# arch-allow:` on the
  # `def`/call line suppresses one site.
  defp resource_kind_as_genserver do
    lib_files()
    |> Enum.map(fn file ->
      case Code.string_to_quoted(read!(file)) do
        {:ok, ast} -> count_resource_kind_as_genserver(ast, arch_allowed_lines(file))
        {:error, _} -> 0
      end
    end)
    |> Enum.sum()
  end

  @doc """
  Testable entry for the `resource_kind_as_genserver` predicate: count the
  Plan-B-shaped violations in a SOURCE STRING (positive/negative fixtures), so the
  K5 gate test can prove a `resource_kinds/0` module IS flagged and a
  `resource_types/0` FsResolver is NOT — without writing fixture files into the
  scanned lib tree. `# arch-allow:` on the offending line suppresses it, same as
  the real scan.
  """
  @spec count_resource_kind_as_genserver_in_source(String.t()) :: non_neg_integer()
  def count_resource_kind_as_genserver_in_source(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> count_resource_kind_as_genserver(ast, allowed_lines_in_source(source))
      {:error, _} -> 0
    end
  end

  # `# arch-allow:` line numbers within a raw source string (fixture-side mirror
  # of `arch_allowed_lines/1`, which reads a file).
  defp allowed_lines_in_source(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _no} -> String.contains?(line, "# arch-allow:") end)
    |> Enum.map(fn {_line, no} -> no end)
    |> MapSet.new()
  end

  defp count_resource_kind_as_genserver(ast, allowed_lines) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, acc ->
        if resource_kind_node?(node, allowed_lines),
          do: {node, acc + 1},
          else: {node, acc}
      end)

    count
  end

  # (a) a `def resource_kinds(...)` / `defp resource_kinds(...)` definition — the
  # Plan-B plugin callback. (Match the def head by name; arity-agnostic.)
  defp resource_kind_node?(
         {def_kw, meta, [{:resource_kinds, _, _args} | _]},
         allowed_lines
       )
       when def_kw in [:def, :defp] do
    not MapSet.member?(allowed_lines, Keyword.get(meta, :line, 0))
  end

  # (b) any `*ResourceKindRegistry.register(...)` call (the registration API a
  # plugin author must never touch for a resource:// → live Kind).
  defp resource_kind_node?(
         {{:., meta, [{:__aliases__, _, aliases}, :register]}, _call_meta, _args},
         allowed_lines
       ) do
    List.last(aliases) == :ResourceKindRegistry and
      not MapSet.member?(allowed_lines, Keyword.get(meta, :line, 0))
  end

  defp resource_kind_node?(_node, _allowed_lines), do: false

  # Subtask B (2026-06-25) — forbid raw `Port.open({:spawn_executable, …}, …)`.
  # The sanctioned OS-process spawn exit is `Ezagent.Runtime.OsProcess` (erlexec
  # `run_link` + `{group,0}`+`:kill_group` subtree reaping); a bare `Port.open`
  # only signals the DIRECT child on close, orphaning the `uv→python` /
  # `codex→vendor` / `node→workers` subtree.
  #
  # AST-based (NOT the line-based `grep/2`): the feishu call spans two lines
  # (`Port.open(` then `{:spawn_executable, …}` on the next), which a per-line
  # regex can never match. The first arg is a BARE 2-tuple `{:spawn_executable,
  # _}` — in Elixir AST a 2-element tuple is a literal `{a, b}`, NOT the `{:{},
  # _, [...]}` form (that is 3+-element tuples like `{:fd, 0, 1}`, which must NOT
  # match). `# arch-allow:` on the `Port.open` line suppresses one site.
  defp raw_port_spawn_executable do
    lib_files()
    |> Enum.map(fn file ->
      case Code.string_to_quoted(read!(file)) do
        {:ok, ast} -> count_port_spawn_executable(ast, arch_allowed_lines(file))
        {:error, _} -> 0
      end
    end)
    |> Enum.sum()
  end

  defp count_port_spawn_executable(ast, allowed_lines) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, acc ->
        if port_spawn_executable_node?(node, allowed_lines),
          do: {node, acc + 1},
          else: {node, acc}
      end)

    count
  end

  defp port_spawn_executable_node?(
         {{:., _, [{:__aliases__, _, [:Port]}, :open]}, meta, [first_arg | _]},
         allowed_lines
       ) do
    not MapSet.member?(allowed_lines, Keyword.get(meta, :line, 0)) and
      (match?({:spawn_executable, _}, first_arg) or
         match?({:{}, _, [:spawn_executable | _]}, first_arg))
  end

  defp port_spawn_executable_node?(_node, _allowed_lines), do: false

  defp manifest do
    @manifest_path
    |> Code.eval_file()
    |> elem(0)
  end

  defp repo_root do
    cwd = File.cwd!()
    if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
  end

  defp lib_files do
    repo_root()
    |> Path.join("apps/*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&relative/1)
    |> Enum.reject(&excluded_file?/1)
    |> Enum.sort()
  end

  defp core_lib_files do
    repo_root()
    |> Path.join("apps/ezagent_core/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&relative/1)
    |> Enum.reject(&excluded_file?/1)
    |> Enum.sort()
  end

  defp excluded_file?(path) do
    # E2E scenario modules (`lib/ezagent/e2e/scenarios/`) are TEST FIXTURES that
    # live under `lib/` only so the running node loads them (the harness resolves
    # them at runtime; `test/` is not compiled into a `mix phx.server` node). They
    # drive production chokepoints (create_session / SpawnRegistry.spawn) for
    # setup, which is legitimate for a scenario but would otherwise inflate the
    # production-caller fitness functions. Exclude them like `/test/`.
    path == @scanner_path or String.contains?(path, "/test/") or
      String.contains?(path, "/e2e/scenarios/")
  end

  defp relative(path), do: Path.relative_to(path, repo_root())

  defp absolute(path), do: Path.join(repo_root(), path)

  defp grep(regex, opts \\ []) do
    skip_comment_lines? = Keyword.get(opts, :skip_comment_lines?, false)

    for file <- lib_files(),
        {line, line_no} <- file_lines(file),
        not String.contains?(line, "# arch-allow:"),
        not (skip_comment_lines? and comment_line?(line)),
        Regex.match?(regex, line) do
      {file, line_no, String.trim(line)}
    end
  end

  defp grep_core(regex) do
    for file <- core_lib_files(),
        {line, line_no} <- file_lines(file),
        not String.contains?(line, "# arch-allow:"),
        not sanctioned_core_tooling_ref?(file, line),
        Regex.match?(regex, line) do
      {file, line_no, String.trim(line)}
    end
  end

  defp sanctioned_core_tooling_ref?(
         "apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex",
         line
       ),
       do: String.contains?(line, "AgentFlavorRegistry")

  defp sanctioned_core_tooling_ref?(_file, _line), do: false

  defp file_lines(file) do
    file
    |> absolute()
    |> File.stream!()
    |> Enum.with_index(1)
  end

  defp comment_line?(line), do: line |> String.trim_leading() |> String.starts_with?("#")

  defp unique_files(hits) do
    hits
    |> Enum.map(fn {file, _line_no, _line} -> file end)
    |> Enum.uniq()
  end

  defp line_count(file) do
    file
    |> absolute()
    |> File.stream!()
    |> Enum.count()
  end

  defp oversized_modules do
    lib_files()
    |> Enum.map(fn file -> {file, line_count(file)} end)
  end

  defp count_oversized(files, threshold) do
    Enum.count(files, fn {_file, count} -> count > threshold end)
  end

  defp def_count(name) do
    @def_count_files
    |> Map.fetch!(name)
    |> file_lines()
    |> Enum.count(fn {line, _line_no} ->
      Regex.match?(~r/^\s*(def|defp)\s+/, line)
    end)
  end

  defp duplicated_resolve_template_class do
    grep(~r/^\s*defp?\s+resolve_template_class/)
    |> Enum.reject(fn {_file, _line_no, line} ->
      Regex.match?(~r/resolve_template_class\(_\)/, line)
    end)
    |> length()
  end

  # FF-1 — count groups of cross-file duplicate function bodies.
  #
  # A "group" is a set of ≥2 DISTINCT lib files that each define a `def`/`defp`
  # whose body — extracted via the real Elixir parser (so brace/`do`/`end`
  # nesting is exact, not a line heuristic) and whitespace-normalized — is
  # byte-identical and at least `@dup_fn_min_body_chars` chars. A
  # behaviour-callback `{name, arity}` is excluded ONLY when its enclosing module
  # declares the owning behaviour (codex r1 HIGH — name-only exemption let a new
  # fork hide behind a callback-shaped name); `# arch-allow:` on the `def`/`defp`
  # line suppresses one specific leg.
  defp cross_file_duplicate_fn_groups do
    lib_files()
    |> Enum.flat_map(&duplicate_candidate_functions/1)
    |> Enum.group_by(fn {_key, norm, _file} -> norm end)
    |> Enum.count(fn {_norm, occurrences} ->
      occurrences
      |> Enum.map(fn {_key, _norm, file} -> file end)
      |> Enum.uniq()
      |> length() >= 2
    end)
  end

  # Countable functions in `file` as `[{{name, arity}, normalized_fn, file}]`.
  #
  # Per ENCLOSING module (codex r2 MEDIUM — exemptions/markers are scoped to the
  # module that owns the function, never file-wide), with all clauses of a
  # `{name, arity}` AGGREGATED into one normalized representation BEFORE the
  # length threshold (codex r2 MEDIUM — a copied multi-clause fork whose
  # individual clauses are each <120 chars is still counted on its aggregate).
  defp duplicate_candidate_functions(file) do
    case Code.string_to_quoted(read!(file)) do
      {:ok, ast} ->
        allowed_lines = arch_allowed_lines(file)

        ast
        |> modules_with_functions()
        |> Enum.flat_map(fn {markers, clauses} ->
          exempt = exempt_callbacks(markers)

          clauses
          # aggregate clauses by {name, arity} → one normalized fn + its min line
          |> Enum.group_by(fn {key, _norm, _line} -> key end)
          |> Enum.map(fn {key, group} ->
            agg = group |> Enum.map(fn {_k, norm, _l} -> norm end) |> Enum.join(" ; ")

            all_allowed? =
              Enum.all?(group, fn {_k, _n, line} -> MapSet.member?(allowed_lines, line) end)

            {key, agg, all_allowed?}
          end)
          |> Enum.reject(fn {key, agg, all_allowed?} ->
            MapSet.member?(@dup_always_exempt, key) or
              MapSet.member?(exempt, key) or
              String.length(agg) < @dup_fn_min_body_chars or
              all_allowed?
          end)
          |> Enum.map(fn {key, agg, _allowed?} -> {key, agg, file} end)
        end)

      {:error, _} ->
        []
    end
  end

  # Each `defmodule` in the AST as `{behaviour_markers, [{key, norm, line}]}` —
  # the module's OWN `use`/`@behaviour` markers paired with the `def`/`defp`
  # clauses lexically inside THAT module's body (nested modules are returned as
  # their own entries via the recursive walk). A non-`defmodule` top form
  # (rare in lib) contributes its bare functions under empty markers.
  defp modules_with_functions(ast) do
    Macro.prewalk(ast, [], fn node, acc ->
      case node do
        {:defmodule, _meta, [_name, [{:do, body} | _]]} ->
          {node, [{module_own_markers(body), module_own_clauses(body)} | acc]}

        _ ->
          {node, acc}
      end
    end)
    |> elem(1)
  end

  # `use X` / `@behaviour X` markers declared DIRECTLY in this module body
  # (stops at a nested `defmodule`, whose markers belong to it, not the parent).
  defp module_own_markers(body) do
    body
    |> top_level_forms()
    |> Enum.flat_map(fn
      {:use, _m, [{:__aliases__, _, mods} | _]} when is_list(mods) -> [dotted(mods)]
      {:@, _m, [{:behaviour, _, [{:__aliases__, _, mods}]}]} when is_list(mods) -> [dotted(mods)]
      _ -> []
    end)
  end

  # `def`/`defp` clauses declared DIRECTLY in this module body (not inside a
  # nested defmodule) as `[{{name, arity}, normalized_body, line}]`.
  defp module_own_clauses(body) do
    body
    |> top_level_forms()
    |> Enum.flat_map(fn
      {kw, meta, [head, [{:do, fbody} | _]]} when kw in [:def, :defp] ->
        case fn_key(head) do
          nil -> []
          key -> [{key, normalize_body(fbody), Keyword.get(meta, :line, 0)}]
        end

      _ ->
        []
    end)
  end

  # The direct child forms of a module/`do` body: a `{:__block__, _, forms}`
  # holds many; a single-statement body is the lone form.
  defp top_level_forms({:__block__, _meta, forms}) when is_list(forms), do: forms
  defp top_level_forms(form), do: [form]

  # The `{name, arity}` callbacks exempt in a module with these markers: the
  # union of callback sets whose owning behaviour's LAST module segment matches a
  # marker's last segment (exact-segment, not substring — codex r2 MEDIUM: a
  # `*Components` use must not match the `Component` owner). A module that does
  # not declare the owner does NOT get its callbacks exempted.
  defp exempt_callbacks(markers) do
    marker_segments = MapSet.new(markers, &last_segment/1)

    @dup_callback_owners
    |> Enum.flat_map(fn {owner, callbacks} ->
      if MapSet.member?(marker_segments, owner), do: callbacks, else: []
    end)
    |> MapSet.new()
  end

  defp last_segment(dotted), do: dotted |> String.split(".") |> List.last()

  defp dotted(mods), do: Enum.map_join(mods, ".", &Atom.to_string/1)

  defp fn_key({:when, _meta, [head | _]}), do: fn_key(head)
  defp fn_key({name, _meta, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp fn_key({name, _meta, nil}) when is_atom(name), do: {name, 0}
  defp fn_key(_), do: nil

  defp normalize_body(body) do
    body
    |> Macro.to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # FF-4 — count distinct non-`agent_bridge`/non-test lib files that still
  # reference a `/cc_socket` deprecation-shim module. Counts caller FILES (the
  # goal is "how many modules are coupled to the shim", which Cleanup-3 ratchets
  # to 0). AST-based so a grouped `alias EzagentPluginCc.{BridgeRegistry, ...}` or
  # a renamed `alias EzagentPluginCc.BridgeRegistry, as: X` is caught too (codex
  # r1 MEDIUM) — a raw fully-qualified-string regex misses both.
  defp cc_bridge_shim_callers do
    shim_set = MapSet.new(@cc_bridge_shim_modules)

    lib_files()
    |> Enum.reject(fn file ->
      file in @cc_bridge_shim_files or String.contains?(file, "/ezagent_domain_agent_bridge/")
    end)
    |> Enum.count(&file_references_shim?(&1, shim_set))
  end

  # domain-only-Kinds gate — plugin-app files declaring a CONCRETE Kind
  # (`@behaviour Ezagent.Kind` exactly; `Ezagent.Kind.Template` is a blueprint a
  # plugin Template Class legitimately declares and is NOT flagged) minus the
  # sanctioned `@plugin_defined_kind_allowlist`. Path-prefix scope on
  # `apps/ezagent_plugin_` so a NEW plugin app is covered automatically. Counted by
  # rejection (never `offenders - length(allowlist)`) so the count can never go
  # negative and mask a regression when the debt shrinks below the allowlist.
  #
  # AST-based (2026-07 batch-1): the `@behaviour` value is matched on the RESOLVED
  # module — so an aliased `alias Ezagent.Kind` + `@behaviour Kind` is caught (a
  # raw `@behaviour Ezagent.Kind` regex would miss it) while `Ezagent.Kind.Template`
  # (or an alias of it) is excluded by exact-module comparison, not a lookahead.
  defp plugin_defined_kinds do
    allow = MapSet.new(@plugin_defined_kind_allowlist)

    plugin_defined_kind_offenders()
    |> Enum.reject(&MapSet.member?(allow, &1))
    |> length()
  end

  # concatenated_namespace_modules (namespace-dot convention gate). Cross-file +
  # per-app: unlike the per-file AST counters, "is `Xyz` a namespace with children"
  # needs every module in the app. Parse every lib file's AST, collect its
  # `defmodule Ezagent.*` names, group by app, and — within each app — count the
  # SINGLE-SEGMENT `Ezagent.XyzAbc` modules that glue an existing namespace prefix
  # (`Ezagent.Xyz` has ≥1 dotted child in that app), minus the sanctioned
  # allowlist. The classification core is the pure `concatenated_namespace_module?/3`
  # (namespaces × module × allowlist), reused by the fixture test.
  defp concatenated_namespace_modules do
    allow = MapSet.new(@concatenated_namespace_allowlist)

    lib_files()
    |> Enum.flat_map(&defmodule_names_with_app/1)
    |> Enum.group_by(fn {app, _segs} -> app end, fn {_app, segs} -> segs end)
    |> Enum.map(fn {_app, module_seg_lists} ->
      namespaces = namespaces_with_children(module_seg_lists)

      module_seg_lists
      |> Enum.filter(&match?([:Ezagent, _single], &1))
      |> Enum.map(&dotted/1)
      |> Enum.count(&concatenated_namespace_module?(namespaces, &1, allow))
    end)
    |> Enum.sum()
  end

  @doc """
  Predicate core of the namespace-dot convention gate: is `module` (a full
  dotted string like `"Ezagent.AgentRecipeResolver"`) a SINGLE-SEGMENT compound
  that glues an existing namespace prefix in `namespaces` (a set of second-level
  segment strings that have dotted children in the same app) and is NOT in
  `allowlist`? Exposed so the fixture test can prove the classifier has teeth
  (`Ezagent.AgentRecipeResolver` with `Agent` a namespace → true; the dotted
  `Ezagent.Agent.RecipeResolver`, an allowlisted compound, and a lone
  `Ezagent.KindSupervisor` when `Kind` is NOT a namespace → false) without
  writing fixture files into the scanned lib tree.
  """
  @spec concatenated_namespace_module?(MapSet.t(String.t()), String.t(), MapSet.t(String.t())) ::
          boolean()
  def concatenated_namespace_module?(namespaces, module, allowlist) do
    not MapSet.member?(allowlist, module) and
      case String.split(module, ".") do
        ["Ezagent", compound] -> glued_namespace_child?(compound, namespaces)
        _ -> false
      end
  end

  # A single-segment compound (`"AgentRecipeResolver"`) is a glued parent+child
  # when any PROPER prefix ending at an internal uppercase boundary (`"Agent"`) is
  # itself a namespace-with-children in the app.
  defp glued_namespace_child?(compound, namespaces) do
    compound
    |> namespace_prefixes()
    |> Enum.any?(&MapSet.member?(namespaces, &1))
  end

  defp namespace_prefixes(compound) do
    len = String.length(compound)

    if len < 2 do
      []
    else
      for i <- 1..(len - 1),
          String.at(compound, i) =~ ~r/[A-Z]/,
          do: String.slice(compound, 0, i)
    end
  end

  # Second-level segments with ≥1 dotted child in the app (`[:Ezagent, :Agent,
  # :RecipeResolver]` → "Agent" is a namespace). Depth-≥3 modules contribute.
  defp namespaces_with_children(module_seg_lists) do
    for [:Ezagent, seg2 | rest] <- module_seg_lists,
        rest != [],
        into: MapSet.new(),
        do: Atom.to_string(seg2)
  end

  # `[{app, segments}]` for every `defmodule Ezagent.*` in `file` (nested modules
  # included via the AST walk); `app` is the umbrella app dir (`ezagent_core`).
  defp defmodule_names_with_app(file) do
    app = app_of(file)

    case Code.string_to_quoted(read!(file)) do
      {:ok, ast} ->
        ast
        |> collect_defmodule_segments()
        |> Enum.filter(&match?([:Ezagent | _], &1))
        |> Enum.map(fn segs -> {app, segs} end)

      {:error, _} ->
        []
    end
  end

  defp app_of("apps/" <> rest), do: rest |> String.split("/", parts: 2) |> hd()
  defp app_of(_), do: "?"

  defp collect_defmodule_segments(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          {:defmodule, _meta, [{:__aliases__, _, segs} | _]} when is_list(segs) ->
            {node, [segs | acc]}

          _ ->
            {node, acc}
        end
      end)

    acc
  end

  @doc """
  Plugin-app lib files that declare a CONCRETE Kind (`@behaviour Ezagent.Kind`
  exactly, alias-resolved) — the domain-only-Kinds offenders BEFORE the sanctioned
  `@plugin_defined_kind_allowlist` is subtracted. Exposed so the gate test can
  prove the AST matcher has TEETH on real code (the allowlisted `hello_builder.ex`
  must appear here) even though the post-allowlist `plugin_defined_kinds` count is
  a target-zero 0.
  """
  @spec plugin_defined_kind_offender_files() :: [String.t()]
  def plugin_defined_kind_offender_files, do: plugin_defined_kind_offenders()

  defp plugin_defined_kind_offenders do
    lib_files()
    |> Enum.filter(&String.starts_with?(&1, "apps/ezagent_plugin_"))
    |> Enum.filter(fn file ->
      case Code.string_to_quoted(read!(file)) do
        {:ok, ast} -> count_plugin_kind_behaviours(ast, arch_allowed_lines(file)) > 0
        {:error, _} -> false
      end
    end)
  end

  @doc """
  Testable entry for the `plugin_defined_kinds` predicate: count the concrete-Kind
  `@behaviour` declarations (`Ezagent.Kind` exactly, alias-resolved) in a SOURCE
  STRING. Proves the robustness gain — an aliased `alias Ezagent.Kind` +
  `@behaviour Kind` IS flagged, while `@behaviour Ezagent.Kind.Template` is NOT —
  without writing fixture files into the scanned plugin tree.
  """
  @spec count_plugin_defined_kinds_in_source(String.t()) :: non_neg_integer()
  def count_plugin_defined_kinds_in_source(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> count_plugin_kind_behaviours(ast, allowed_lines_in_source(source))
      {:error, _} -> 0
    end
  end

  defp count_plugin_kind_behaviours(ast, allowed_lines) do
    amap = module_alias_map(ast)

    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, acc ->
        case node do
          {:@, _, [{:behaviour, meta, [{:__aliases__, _, mods}]}]} when is_list(mods) ->
            if resolve_full_module(mods, amap) == [:Ezagent, :Kind] and
                 not MapSet.member?(allowed_lines, Keyword.get(meta, :line, 0)) do
              {node, acc + 1}
            else
              {node, acc}
            end

          _ ->
            {node, acc}
        end
      end)

    count
  end

  # True iff `file` references any shim module, whether fully-qualified, via a
  # plain/grouped `alias`, or a renamed `alias ..., as: X` whose alias is then
  # used as a remote-call/reference target. `# arch-allow:` on the line suppresses.
  defp file_references_shim?(file, shim_set) do
    case Code.string_to_quoted(read!(file)) do
      {:ok, ast} ->
        allowed_lines = arch_allowed_lines(file)
        aliases = shim_alias_names(ast, shim_set)
        shim_reference?(ast, shim_set, aliases, allowed_lines)

      {:error, _} ->
        # Parse failure: fall back to a conservative fully-qualified text scan so
        # an unparseable file still can't silently hide a shim caller.
        regex = cc_bridge_shim_fqn_regex()

        file
        |> file_lines()
        |> Enum.any?(fn {line, _no} ->
          not String.contains?(line, "# arch-allow:") and Regex.match?(regex, line)
        end)
    end
  end

  # Set of single-segment alias atoms that resolve to a shim module:
  # `alias EzagentPluginCc.BridgeRegistry` → :BridgeRegistry;
  # `alias EzagentPluginCc.{Socket, Channel}` → :Socket, :Channel;
  # `alias EzagentPluginCc.TokenStore, as: TS` → :TS.
  defp shim_alias_names(ast, shim_set) do
    {_ast, names} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          # alias A.B.C, as: X
          {:alias, _m, [{:__aliases__, _, mods}, opts]} when is_list(mods) and is_list(opts) ->
            if MapSet.member?(shim_set, mods) do
              case Keyword.get(opts, :as) do
                {:__aliases__, _, [as_atom]} -> {node, [as_atom | acc]}
                _ -> {node, [List.last(mods) | acc]}
              end
            else
              {node, acc}
            end

          # alias A.B.C  (plain)
          {:alias, _m, [{:__aliases__, _, mods}]} when is_list(mods) ->
            if MapSet.member?(shim_set, mods),
              do: {node, [List.last(mods) | acc]},
              else: {node, acc}

          # alias A.B.{C, D}  (grouped)
          {:alias, _m, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} ->
            grouped =
              for {:__aliases__, _, child_mods} <- children,
                  MapSet.member?(shim_set, base ++ child_mods),
                  do: List.last(child_mods)

            {node, grouped ++ acc}

          _ ->
            {node, acc}
        end
      end)

    MapSet.new(names)
  end

  # True iff the AST contains a fully-qualified shim module reference OR a use of
  # one of the resolved single-segment shim aliases.
  defp shim_reference?(ast, shim_set, aliases, allowed_lines) do
    {_ast, hit?} =
      Macro.prewalk(ast, false, fn node, acc ->
        if acc do
          {node, acc}
        else
          {node, acc or shim_node?(node, shim_set, aliases, allowed_lines)}
        end
      end)

    hit?
  end

  defp shim_node?({:__aliases__, meta, mods}, shim_set, aliases, allowed_lines)
       when is_list(mods) do
    not line_allowed?(meta, allowed_lines) and
      (MapSet.member?(shim_set, mods) or
         (match?([_single], mods) and MapSet.member?(aliases, List.first(mods))))
  end

  defp shim_node?(_node, _shim_set, _aliases, _allowed_lines), do: false

  defp line_allowed?(meta, allowed_lines) do
    MapSet.member?(allowed_lines, Keyword.get(meta, :line, 0))
  end

  defp arch_allowed_lines(file) do
    file
    |> file_lines()
    |> Enum.filter(fn {line, _no} -> String.contains?(line, "# arch-allow:") end)
    |> Enum.map(fn {_line, no} -> no end)
    |> MapSet.new()
  end

  # Conservative fully-qualified fallback regex (parse-failure path only).
  defp cc_bridge_shim_fqn_regex do
    alternation = Enum.map_join(@cc_bridge_shim_modules, "|", &dotted/1)
    Regex.compile!("(#{alternation})(?![A-Za-z0-9_])")
  end

  # --- AST-based remote-call chokepoint counters (2026-07 batch-1) ------------
  #
  # `spawn_registry_call_sites/modules/off_chokepoint` and
  # `create_session_call_sites/modules` were per-line `grep`s. Both are now
  # AST-based: a remote call `Mod.fun(args)` is matched on the RESOLVED module
  # (so `alias Ezagent.SpawnRegistry, as: SR` + `SR.spawn(...)` is caught) and
  # ONLY when the call has parentheses — which excludes a function capture
  # `&Mod.fun/arity` (grep never matched those either) and mirrors the old
  # `\.fun\(` regex. Moduledoc/comment/string mentions are gone by construction
  # (they are not AST call nodes). `# arch-allow:` on the call line suppresses.
  # Emits `{file, line, :ast}` triples so `unique_files/1` + `unsanctioned_count/2`
  # keep working unchanged.

  # SpawnRegistry.spawn / spawn_detailed call sites (module resolved to
  # `Ezagent.SpawnRegistry` by last-segment, faithful to the old last-segment grep).
  defp spawn_registry_call_hits do
    ast_call_hits(fn last_segment, fun ->
      fun in [:spawn, :spawn_detailed] and last_segment == :SpawnRegistry
    end)
  end

  # `.create_session(` facade call sites (module-agnostic, mirroring the old
  # `\.create_session\(` grep — any receiver, incl. a `facade.create_session(...)`
  # variable receiver).
  defp create_session_call_hits do
    ast_call_hits(fn _last_segment, fun -> fun == :create_session end)
  end

  @doc """
  Testable entry for the `spawn_registry_*` counters: count SpawnRegistry
  `spawn`/`spawn_detailed` call sites in a SOURCE STRING. Proves the robustness
  gain — an `alias Ezagent.SpawnRegistry, as: SR` + `SR.spawn(uri)` IS counted
  (a raw `SpawnRegistry.spawn(` grep would miss the aliased form) while a
  `&Ezagent.SpawnRegistry.spawn/1` capture and a moduledoc mention are NOT.
  """
  @spec count_spawn_registry_calls_in_source(String.t()) :: non_neg_integer()
  def count_spawn_registry_calls_in_source(source) when is_binary(source) do
    count_calls_in_source(source, fn last_segment, fun ->
      fun in [:spawn, :spawn_detailed] and last_segment == :SpawnRegistry
    end)
  end

  @doc """
  Testable entry for the `create_session_*` counters: count `create_session`
  facade call sites in a SOURCE STRING. Proves an `alias A.B, as: F` +
  `F.create_session(...)` IS counted and a `&Mod.create_session/3` capture is NOT.
  """
  @spec count_create_session_calls_in_source(String.t()) :: non_neg_integer()
  def count_create_session_calls_in_source(source) when is_binary(source) do
    count_calls_in_source(source, fn _last_segment, fun -> fun == :create_session end)
  end

  # Walk every lib file's AST; return `[{file, line, :ast}]` for each remote-call
  # node whose `{resolved_last_segment, fun}` satisfies `match_fun`.
  defp ast_call_hits(match_fun) when is_function(match_fun, 2) do
    Enum.flat_map(lib_files(), fn file ->
      case Code.string_to_quoted(read!(file)) do
        {:ok, ast} ->
          amap = module_alias_map(ast)
          allowed = arch_allowed_lines(file)

          ast
          |> collect_remote_call_lines(amap, allowed, match_fun)
          |> Enum.map(fn line -> {file, line, :ast} end)

        {:error, _} ->
          []
      end
    end)
  end

  defp count_calls_in_source(source, match_fun) when is_function(match_fun, 2) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        collect_remote_call_lines(
          ast,
          module_alias_map(ast),
          allowed_lines_in_source(source),
          match_fun
        )
        |> length()

      {:error, _} ->
        0
    end
  end

  # Lines of every parenthesized remote call `Mod.fun(args)` in `ast` whose
  # `{resolved_last_segment, fun}` matches `match_fun` and is not `# arch-allow:`ed.
  defp collect_remote_call_lines(ast, amap, allowed_lines, match_fun) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          {{:., _dot_meta, [receiver, fun]}, meta, args}
          when is_atom(fun) and is_list(args) ->
            line = Keyword.get(meta, :line, 0)

            if not Keyword.get(meta, :no_parens, false) and
                 match_fun.(resolved_last_segment(receiver, amap), fun) and
                 not MapSet.member?(allowed_lines, line) do
              {node, [line | acc]}
            else
              {node, acc}
            end

          _ ->
            {node, acc}
        end
      end)

    lines
  end

  # The last module segment of a call's receiver, resolving a single-segment
  # alias through `amap` (`SR` → `Ezagent.SpawnRegistry` → `:SpawnRegistry`).
  # Non-alias receivers (a bare var like `facade`) resolve to `nil` (module-agnostic
  # matchers ignore it).
  defp resolved_last_segment({:__aliases__, _meta, mods}, amap) when is_list(mods) do
    case mods do
      [single] -> List.last(Map.get(amap, single, [single]))
      _ -> List.last(mods)
    end
  end

  defp resolved_last_segment(_receiver, _amap), do: nil

  # Resolve a `@behaviour`/reference module-segment list to its FULL alias target
  # (`[:Kind]` with `alias Ezagent.Kind` → `[:Ezagent, :Kind]`). Multi-segment
  # refs are already absolute.
  defp resolve_full_module([single], amap), do: Map.get(amap, single, [single])
  defp resolve_full_module(mods, _amap) when is_list(mods), do: mods

  # `%{alias_atom => full_segment_list}` for every `alias` in the AST — plain,
  # `as:`-renamed, and grouped `alias A.B.{C, D}`. Mirrors `shim_alias_names/2`'s
  # resolution but keyed by the full target so any module can be resolved.
  defp module_alias_map(ast) do
    {_ast, map} =
      Macro.prewalk(ast, %{}, fn node, acc ->
        case node do
          # alias A.B.C, as: X
          {:alias, _m, [{:__aliases__, _, mods}, opts]} when is_list(mods) and is_list(opts) ->
            case Keyword.get(opts, :as) do
              {:__aliases__, _, [as_atom]} -> {node, Map.put(acc, as_atom, mods)}
              _ -> {node, Map.put(acc, List.last(mods), mods)}
            end

          # alias A.B.C  (plain)
          {:alias, _m, [{:__aliases__, _, mods}]} when is_list(mods) ->
            {node, Map.put(acc, List.last(mods), mods)}

          # alias A.B.{C, D}  (grouped)
          {:alias, _m, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} ->
            grouped =
              for {:__aliases__, _, child} <- children,
                  into: %{},
                  do: {List.last(child), base ++ child}

            {node, Map.merge(acc, grouped)}

          _ ->
            {node, acc}
        end
      end)

    map
  end

  defp raw_home_path_outside_core do
    grep(~r/Home\.path\(/)
    |> Enum.reject(fn {file, _line_no, _line} ->
      String.starts_with?(file, "apps/ezagent_core/")
    end)
    |> length()
  end

  defp unsanctioned_count(hits, sanctioned) do
    sanctioned = MapSet.new(sanctioned)

    hits
    |> Enum.reject(fn {file, line_no, _line} -> MapSet.member?(sanctioned, {file, line_no}) end)
    |> length()
  end

  defp cross_slice_set_violations(set_effect_hits) do
    known_slices = known_state_slices()

    set_effect_hits
    |> Enum.filter(fn {file, _line_no, line} ->
      case set_effect_key(line) do
        nil ->
          false

        key ->
          owner = file_state_slice(file)
          MapSet.member?(known_slices, key) and owner != key
      end
    end)
    |> length()
  end

  defp known_state_slices do
    lib_files()
    |> Enum.flat_map(fn file ->
      file
      |> file_lines()
      |> Enum.flat_map(fn {line, _line_no} ->
        cond do
          match = Regex.run(~r/state_slice:\s*:([a-z_]+)/, line) ->
            [String.to_atom(Enum.at(match, 1))]

          match = Regex.run(~r/def\s+state_slice,\s*do:\s*:([a-z_]+)/, line) ->
            [String.to_atom(Enum.at(match, 1))]

          true ->
            []
        end
      end)
    end)
    |> MapSet.new()
  end

  defp file_state_slice(file) do
    file
    |> file_lines()
    |> Enum.find_value(fn {line, _line_no} ->
      cond do
        match = Regex.run(~r/state_slice:\s*:([a-z_]+)/, line) ->
          String.to_atom(Enum.at(match, 1))

        match = Regex.run(~r/def\s+state_slice,\s*do:\s*:([a-z_]+)/, line) ->
          String.to_atom(Enum.at(match, 1))

        true ->
          nil
      end
    end)
  end

  defp set_effect_key(line) do
    case Regex.run(~r/\{:set,\s*:([a-z_]+),/, line) do
      [_, key] -> String.to_atom(key)
      _ -> nil
    end
  end

  defp missing_cap_check_mutating_actions do
    invariant_test =
      "apps/ezagent_core/test/ezagent/behavior_required_caps_action_invariant_test.exs"

    runtime = read!(@runtime_file)
    verifier = read!("apps/ezagent_core/lib/ezagent/cap/verifier.ex")
    authorizer = read!("apps/ezagent_core/lib/ezagent/cap/authorize.ex")

    cond do
      not File.exists?(absolute(invariant_test)) ->
        1

      not String.contains?(runtime, "Ezagent.Cap.Verifier.authorize") ->
        1

      not String.contains?(verifier, "Ezagent.Cap.authorize(holder") ->
        1

      not String.contains?(authorizer, "Capability.matches?") ->
        1

      true ->
        0
    end
  end

  defp kind_runtime_ordering_violations do
    runtime = read!(@runtime_file)

    authz = index_of(runtime, "Ezagent.Cap.Verifier.authorize")
    workspace = index_of(runtime, "workspace_isolation_check(")
    invoke = index_of(runtime, "invoke_behavior(")

    if ordered?([authz, workspace, invoke]), do: 0, else: 1
  end

  defp kind_runtime_reentry_violations do
    runtime = read!(@runtime_file)
    target_ownership = function_body(runtime, "target_ownership_check")
    event_to_payload = function_body(runtime, "event_to_payload")

    [target_ownership, event_to_payload]
    |> Enum.count(fn body ->
      String.contains?(body, "Invocation.dispatch(") or String.contains?(body, "Router.dispatch(")
    end)
  end

  defp cold_restart_respawn_round_trip_drift do
    required_gates = [
      {"apps/ezagent_core/test/e2e/scenario_25_phx_restart_rebuild_test.exs",
       ["snapshot", "restart"]},
      {"apps/ezagent_core/test/integration/snapshot_restart_test.exs", ["caps", "restart"]},
      {"apps/ezagent_core/test/ezagent/behavior/sandbox_cold_restart_test.exs",
       ["respawn_template_data", "cold"]}
    ]

    Enum.count(required_gates, fn {file, needles} ->
      not File.exists?(absolute(file)) or
        not Enum.all?(needles, &String.contains?(read!(file), &1))
    end)
  end

  defp ordered?(indexes) do
    Enum.all?(indexes, &is_integer/1) and indexes == Enum.sort(indexes)
  end

  defp index_of(contents, needle) do
    case :binary.match(contents, needle) do
      {idx, _len} -> idx
      :nomatch -> nil
    end
  end

  defp function_body(contents, name) do
    case Regex.run(~r/defp?\s+#{Regex.escape(name)}\b[\s\S]*?(?=\n\s*defp?\s|\z)/, contents) do
      [body] -> body
      _ -> ""
    end
  end

  defp read!(file), do: file |> absolute() |> File.read!()
end
