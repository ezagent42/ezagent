defmodule Ezagent.SystemPrincipal.Catalog do
  @moduledoc """
  The closed allowlist of system principal URIs and their permitted caps.

  Any `system://` URI used as a dispatch principal MUST appear here.
  `:ezagent_plugin_check` enforces this at compile time (Issue 3);
  the runtime `SystemPrincipal.ensure/1` enforces it at boot;
  invariant test `no_admin_caps_fallback_test.exs` is the test-time gate.

  Adding a 15th principal requires:
  1. Add row here.
  2. Update SPEC `2026-05-25-caps-cleanup-v1.md` §4.1 catalog table.
  3. Ship in a separate PR (review surface = "are we adding ambient authority?").

  Per `feedback_let_it_crash_no_workarounds` — every entry is closed;
  there is no fallback path that mints an ad-hoc principal.

  ## Cap structs (PR-CC-2-v2)

  The catalog records `%Ezagent.Capability{}` struct values. Pre-PR-CC-2-v2
  (PR-CC-1's window) the catalog held string-cap lists and PR-CC-1's
  `SystemPrincipal.caps/1` bridge minted ONE wildcard cap per non-empty
  entry — a coarse-grained authorization slip until the struct-shape
  conversion landed.

  PR-CC-2-v2 (SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md`
  §5) closes that gap. Each entry's struct(s) precisely encode the
  Behavior's actual `required_caps/0` shape, so dispatch step 5.5's
  `holds_cap?/2` consults a structurally narrowed cap set instead of
  a uniform wildcard. Two principals retain full-wildcard caps:
  `system://bootstrap` (the all-caps invariant per Decision #81 + SPEC
  v3 §4.4) and `system://mix-task` (operator-driven; same authority as
  admin User per in-VM trust §10.5). All others are narrowed.

  ## Deviations from SPEC §5 provisional table

  The PR-CC-2-v2 implementing subagent verified each action atom
  against the actual `Behavior.<Module>.actions/0` on main and corrected
  the SPEC's provisional atoms:

  - `system://chat-router` originally had `session.chat.system_message` —
    `:system_message` is NOT an action on `Behavior.Session` (the action
    list is `[:send, :receive, :join, :leave, :set_working_copy]`); the
    string was a dead cap. The struct entry KEEPS only `:send` — the
    only chat-router action that actually fires in dispatch.
  - `system://chat-reply` originally had `session.chat.reaction` —
    same situation; `:reaction` is not an action. KEEPS only `:send`.
  - `system://template-materialize` originally had `workspace.template.*` —
    `workspace.template.*` doesn't structurally map (Template Behavior
    lives on AgentTemplate/SessionTemplate Kinds, not Workspace). The
    intent was "template materialization across all template actions
    + spawning sessions"; mapped to a `Behavior.Template :any-action`
    cap on the `:any`-Kind axis (template:// is cross-cutting; SPEC §2b
    Template.workspace_scoped? = false) + the session-spawning cap.
  - `system://session-internal` originally had `workspace.workspace.read` —
    Workspace has no `:read` action (its read actions are `:list_members`,
    `:list_templates`, etc.). Mapped to a `Behavior.Workspace :any-action`
    cap so session-internal can call any read-shaped workspace action;
    if narrowed later, this becomes the explicit list.

  Refinement on the `:any-action` shape: the cap struct doesn't carry
  an `:action` field (per SPEC §4 footnote — action is the map key in
  `required_caps/0`). When a system principal needs authority across
  multiple actions of one Behavior, we hold ONE cap with the matching
  `kind` + `behavior` axis; `Capability.matches?/2` ignores action
  axis (since it's not on the struct), so the cap matches every action
  on that Behavior. This is structurally equivalent to "behavior wildcard"
  while keeping the per-Kind narrowing.
  """

  alias Ezagent.Capability

  # Aliases for the Behavior modules referenced below. Inline-aliased
  # for readability; lazy-loaded at compile time so behavior modules
  # from non-loaded apps (e.g. plugin Behaviors during a core-only
  # build) don't break.
  #
  # Allen 2026-05-26 — `alias Ezagent.Behavior.ApiKeys` removed (and
  # the `cap(:user, ApiKeys, :get_api_key)` Catalog entry it served):
  # post ApiKeys-to-Agent flip CurlAgent reads its own `:api_keys`
  # slice in-process via `ctx[:sibling_slices]`, so no system principal
  # dispatches `identity.get_api_key` anymore.
  alias Ezagent.Behavior.Session
  alias Ezagent.Behavior.ExternalMirror
  alias Ezagent.Behavior.ExternalMirrorWorker
  alias Ezagent.Behavior.Identity
  alias Ezagent.Behavior.IdentityAdmin
  # 2026-05-26 — Publisher.SessionImpl lives in `ezagent_domain_session`.
  # Like the other Behavior aliases in this block, the module is
  # resolved at runtime (catalog evaluation), not compile time, so
  # core's no-umbrella-dep rule is preserved.
  alias Ezagent.Behavior.Publisher.SessionImpl, as: PublisherSI
  alias Ezagent.Behavior.Sandbox
  alias Ezagent.Behavior.Template
  alias Ezagent.Behavior.Workspace

  # The bootstrap structural sentinel — granted_by/granted_at on the
  # generated wildcard cap so `admin_invariant?/1` recognises it.
  @bootstrap_granted_at ~U[2026-01-01 00:00:00Z]

  defp bootstrap_wildcard do
    %Capability{
      kind: :any,
      behavior: :any,
      # SPEC 2026-05-27 capability-action-axis — bootstrap admin
      # invariant is FIVE-axis wildcard. The admin_invariant?/1
      # predicate matches this exact shape.
      action: :any,
      instance: :any,
      workspace_uri: :any,
      granted_by: Ezagent.URI.system(:bootstrap, :default),
      granted_at: @bootstrap_granted_at
    }
  end

  @doc """
  The closed allowlist mapped from principal URI →
  `[%Capability{}]` cap list. (#17 cascade PR-0 added
  `system://credential-materializer` — an empty-cap audit identity.)

  Implemented as a function (not a module attribute) so the bootstrap
  wildcard's granted_by/granted_at can use `@bootstrap_granted_by` +
  `@bootstrap_granted_at` directly without compile-time DateTime
  literal limitations.

  Use `caps_for!/1` and `member?/1` for the public API; this is exported
  so the no-wildcard invariant test (`no_wildcard_system_principals_test.exs`,
  SPEC §5) can iterate entries directly.
  """
  @spec entries() :: [{String.t(), [%Ezagent.Capability{}]}]
  def entries do
    [
      {principal(:bootstrap), [bootstrap_wildcard()]},
      {principal("boot-reconciler"),
       [
         # boot reconciler dispatches against external_mirror Behavior
         # on Session Kind (bind/unbind/list_bindings) — matches the
         # original `session.external_mirror.*` glob via the
         # behavior-wildcard pattern.
         Capability.cap(:session, ExternalMirror, :any)
       ]},
      {principal("adapter-install"),
       [
         # adapter-install fires session.<flavor>.bind — the bind action
         # is the ExternalMirror Behavior's gate. Narrowed to bind.
         Capability.cap(:session, ExternalMirror, :bind)
       ]},
      {principal("chat-router"),
       [
         # `cap(:any, Session, :any)` covers Session-registered receivers
         # (Session, User). But chat fan-out also dispatches
         # `chat.receive` to Agent Kinds whose BehaviorRegistry routes
         # `:receive` to a PLUGIN-DEFINED Behavior (e.g. Echo's
         # `Behavior.Echo` for `entity://agent/<ws>/echo_X`). Each
         # plugin declares its own `required_caps[:receive]`; the
         # catalog cannot enumerate them across the open plugin set.
         # The wildcard cap is therefore STRUCTURAL — chat-router
         # legitimately needs admin authority for the `:receive` fan-out.
         # This is the smallest deviation from the bootstrap-wildcard
         # bridge that preserves the open-plugin chat-router semantic;
         # the SPEC §5 narrowing applies to single-Behavior principals
         # (workspace-loader, agent-internal, …) which have a closed
         # cap set.
         bootstrap_wildcard()
       ]},
      {principal("chat-reply"),
       [
         # Same rationale as chat-router — Plugin CC's channel
         # dispatches `chat.send` AND `chat.receive` across plugin
         # Behaviors (Echo, NpAgent, …). Wildcard is the structural
         # right shape for an open-plugin fan-out principal.
         bootstrap_wildcard()
       ]},
      {principal("worker-publish"),
       [
         Capability.cap(:external_mirror_worker, ExternalMirrorWorker, :publish),
         # 2026-05-26 (Allen e2e blocker): Worker.subscribe_to_session_publisher/2
         # dispatches `session://...?action=publisher.subscribe_from` to
         # subscribe to its bound session's Publisher (SPEC §8.1).
         # CapBAC step 5.5 needs the cap shape registered against the
         # Session Kind by `EzagentDomainInstanceMessage.Application` — see
         # `CapabilityRegistry.register(Session, action, PublisherSI)`
         # over `PublisherSI.actions()` = `[:subscribe_from, :snapshot,
         # :history]`. Without this cap the worker is stuck in a
         # `:unauthorized` retry loop the moment a binding is created;
         # outbound external_mirror never delivers a single event.
         Capability.cap(:session, PublisherSI, :subscribe_from)
       ]},
      {principal("template-materialize"),
       [
         # Deviation: original `workspace.template.*` doesn't structurally
         # map (Template lives on AgentTemplate/SessionTemplate). Mapped
         # to a Template Behavior cap on :any-Kind (template:// is
         # cross-cutting). The session-spawn half of the original glob
         # `session.*` becomes a Session-wildcard cap on Session Kind.
         # PR-CC-2-v2 added IdentityAdmin grant_cap on User — the
         # `grant_owner_template_cap/2` flow in SessionTemplate.create/3
         # / fork/3 dispatches `identity.grant_cap` on the owner User
         # Kind under this principal (template materialization side-
         # effect). Pre-PR-CC-2-v2 worked because the bridge widened
         # every non-empty entry to a wildcard cap; post-narrowing this
         # MUST be declared structurally. The Workspace Behavior cap
         # (`workspace_uri: :any`) is the cross-workspace authority
         # needed so `IdentityAdmin.check_grant_authorized` accepts the
         # principal as a "workspace admin" for the target workspace
         # (per the PR-CC-2-v2 amendment to `holds_workspace_admin_cap?`).
         Capability.cap(:any, Template, :any),
         Capability.cap(:session, Session, :any),
         Capability.cap(:user, IdentityAdmin, :grant_cap),
         # 2026-05-31 orchestrator-startup-atomicity §4 step 9
         # (codex-review Q1) — rollback is the symmetric INVERSE of the
         # materialization grant: `EzagentDomainInstanceMessage.rollback_session/3`
         # dispatches `identity.revoke_cap` (owner restart cap +
         # orchestrator scoped caps) under THIS principal. Without the
         # revoke_cap cap those revokes are denied and the owner restart
         # cap survives on the durable owner User Kind — exactly the Q1
         # residue. Symmetric with the grant_cap above.
         Capability.cap(:user, IdentityAdmin, :revoke_cap),
         Capability.cap(:workspace, Workspace, :any)
       ]},
      {principal("orchestrator-tools"),
       [
         # `session.*` → Session behavior on Session (orchestrator tools
         # write into the session's chat slice).
         Capability.cap(:session, Session, :any),
         # `agent.identity.list_caps` — the MCP McpServer loads the
         # orchestrator AGENT's OWN four delegated caps from its
         # `:identity` slice under this principal
         # (`McpServer.load_orchestrator_caps/1` dispatches
         # `identity.list_caps` against the agent URI). Identity is hosted
         # on the Agent Kind, so the principal needs an agent-scoped
         # list_caps cap; without it the cap load returns empty and every
         # orchestrator tool runs cap-less → unauthorized.
         Capability.cap(:agent, Identity, :list_caps)
       ]},
      {principal("session-internal"),
       [
         # Deviation: original `workspace.workspace.read` mapped to a
         # Workspace Behavior wildcard cap so session-internal can read
         # any workspace state. Original `session.chat.*` widened to
         # `:any`-Kind Session — session-internal dispatches `chat.receive`
         # on User AND Agent Kinds during fan-out, so the Kind axis must
         # cross those (same multi-Kind pattern as chat-router).
         Capability.cap(:any, Session, :any),
         Capability.cap(:workspace, Workspace, :any)
       ]},
      {principal("agent-internal"),
       [
         # 2026-06-16 (Decision #154 "no unowned permissions", Allen's ruling) —
         # `cap(:user, IdentityAdmin, :grant_cap)` DROPPED. It was vestigial: the
         # PR-CC-2-v2 bootstrap-wildcard bridge once masked a dependency, but a
         # repo-wide `git grep` (2026-06-16) confirms NO live `grant_cap`/`revoke_cap`
         # dispatch ever ran under `system://agent-internal` as caller — its only
         # live use is the `sandbox.write_path` self-authority below
         # (`template_spawn.ex:523`, a `Sandbox` action). Dropping it makes
         # agent-internal a NON-minter → category A in the no-unowned gate. The
         # honest granter for any future agent-creation cap grant is the agent's
         # creator entity (via manager-delegation #153), never this abstract
         # principal.
         # Agent.do_record_sandbox_state/3 dispatches sandbox.write_path
         # under this principal (pathology-B follow-up: PR-CC-2-v2's
         # bootstrap-wildcard bridge masked this dependency). The cap
         # is narrowed to the exact Behavior + action; the runtime
         # dispatch path substitutes the per-agent instance + workspace.
         Capability.cap(:agent, Sandbox, :write_path)
         # 2026-06-11 — `cap(:agent, Sandbox, :read)` was part of
         # `system://agent-internal` for #607 self-evolve (SW-UPD), when
         # `Socialware.CascadeRepoint` reached ACROSS the entity boundary to
         # read+rewrite a target agent's `cascade_resolution`. Config-evolve
         # is now AGENT-OWNED (`Ezagent.Behavior.ConfigEvolve` on the Agent
         # Kind, spec 2026-06-11): the agent reads its OWN `:sandbox` sibling
         # slice IN-PROCESS (no dispatch, no cap) and the cascade write is the
         # agent acting on ITSELF under its self-scoped
         # `cap(:agent, Sandbox, :write_path)`. So the cross-entity read
         # escalation is dropped — same play as the ApiKeys-to-Agent flip
         # below. `:write_path` STAYS (still used by
         # `Agent.do_record_sandbox_state/3` above).
         # Allen 2026-05-26 — `cap(:user, ApiKeys, :get_api_key)` was
         # part of `system://agent-internal` pre ApiKeys-to-Agent flip.
         # Post-flip, ApiKeys lives on the agent's own Kind and the
         # CurlAgent reads its OWN slice via `ctx[:all_slices][:api_keys]`
         # IN-PROCESS (the deadlock-free path) — no dispatch, hence no
         # cap required. The entry is dropped from this principal.
       ]},
      {principal("workspace-loader"),
       [
         # `workspace.workspace.*` → Workspace Behavior on Workspace Kind.
         Capability.cap(:workspace, Workspace, :any)
       ]},
      {principal("mix-task"),
       [
         # Operator-driven; same authority as admin User by deployment
         # contract (in-VM trust model §10.5). Wildcard cap is
         # explicitly exempted from the no-wildcard invariant test.
         bootstrap_wildcard()
       ]},
      {principal("feishu-binding-policy"),
       [
         # `user.identity.grant_cap` → IdentityAdmin Behavior on User.
         Capability.cap(:user, IdentityAdmin, :grant_cap),
         # Workspace cap (any workspace) — so the policy can grant
         # `User.default_caps/1` (which mints session-scoped caps with
         # a concrete workspace_uri); `check_grant_authorized` requires
         # workspace-admin authority for the target workspace, and a
         # `:any`-workspace `Workspace` cap satisfies that check (see
         # `holds_workspace_admin_cap?/2`). Pathology-B follow-up:
         # before the bootstrap-wildcard bridge removal, the policy
         # received admin authority transitively and didn't need this
         # explicit cap.
         Capability.cap(:workspace, Workspace, :any)
       ]},
      {principal("lv-anon-mount"), []},
      # #17 cascade PR-0 (spec §5.1, codex H1) — the credential-materializer
      # IDENTITY. This is an AUDIT identity only: it holds NO standing caps. The
      # least-privilege source-read authority is a NARROW `Capability.cap/5`
      # derived per-grant at materialize time (see `Ezagent.Credential.GrantCap`)
      # and passed as the dispatch caps for the single `sandbox.read` on the
      # validated source. A broad standing cap here would defeat the per-source
      # scoping — so the entry is deliberately empty (like `lv-anon-mount`).
      {principal("credential-materializer"), []},
      # #51 external-user anonymous access (§3.4 GC) — the in-app GC sweeper
      # (`Ezagent.Socialware.AnonUser.Sweeper`) reaps abandoned anon-Users: it
      # `chat.leave`s each from its session under THIS principal. Narrowed to
      # exactly Session `:leave` — the `users` row + binding row deletes are
      # direct context fns (`Users.delete/1` + `AnonBinding.claim_for_reaping/3` /
      # `delete/1`), NOT dispatches, so they need no cap. The anon-User holds an EMPTY
      # caps_json and cannot self-leave (spec §3.3), so the system sweeper needs
      # this grant (Allen 2026-06-15 — Option A: a dedicated closed-catalog GC
      # principal, not ambient/per-session authority).
      {principal("socialware-gc"), [Capability.cap(:session, Session, :leave)]}
    ]
  end

  @doc "Is this URI a registered system principal?"
  @spec member?(URI.t() | String.t()) :: boolean()
  def member?(uri) do
    key = normalize(uri)
    Enum.any?(entries(), fn {entry_uri, _caps} -> entry_uri == key end)
  end

  @doc """
  Permitted caps for this principal. Raises if not in catalog.

  Per `feedback_let_it_crash_no_workarounds` — bad URI is a programmer
  error, not a degradable runtime state.

  Returns `[%Ezagent.Capability{}]` (struct shape, post-PR-CC-2-v2).
  """
  @spec caps_for!(URI.t() | String.t()) :: [%Ezagent.Capability{}]
  def caps_for!(uri) do
    key = normalize(uri)

    case Enum.find(entries(), fn {entry_uri, _caps} -> entry_uri == key end) do
      {_uri, caps} ->
        caps

      nil ->
        raise ArgumentError,
              "#{key} is not in Ezagent.SystemPrincipal.Catalog " <>
                "(SPEC caps-cleanup-v1 §4.1). " <>
                "Add the row to Catalog + SPEC + open a separate PR."
    end
  end

  @doc "List every catalog URI (for invariant test §9.5)."
  @spec uris() :: [String.t()]
  def uris, do: Enum.map(entries(), fn {uri, _caps} -> uri end)

  defp principal(name), do: name |> Ezagent.URI.system_principal() |> URI.to_string()

  defp normalize(%URI{} = u), do: URI.to_string(u)
  defp normalize(s) when is_binary(s), do: s
end
