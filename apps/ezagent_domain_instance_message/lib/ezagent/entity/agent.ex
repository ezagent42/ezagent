defmodule Ezagent.Entity.Agent do
  @moduledoc """
  Agent Kind — represents an external participant (e.g. a Claude CLI
  session via the CC bridge) inside ESR's chat router.

  Per Decision #61: an Agent is a peer of admin User in the Session —
  it can send messages (when its bridge surfaces a reply) and receive
  messages (forwarded by Session). The bridge wire is provided by
  AgentBridge (Phoenix.Channel WebSocket); the Agent
  Kind itself stays transport-agnostic.

  ## Spawn lifecycle

  Two paths spawn an Agent Kind:

  1. **Cold spawn** from a workspace's `cc.pty` Template Class →
     the cc Template Class starts a PtyServer
     which writes the v2 mcp.json; claude reads it and spawns the
     Python WS bridge.

  2. **Channel-join spawn** when the WS bridge joins
     `cc:bridge:<agent_uri>` — the AgentBridge channel
     calls `Ezagent.SpawnRegistry.spawn(agent_uri)` to ensure the
     Agent Kind exists in `KindRegistry` before binding the channel
     pid to it (PR 32a).

  Both paths land at:

      Ezagent.SpawnRegistry.spawn(agent_uri)
        → Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})

  (V1 prevention, Allen 2026-05-21: `Ezagent.Kind.spawn/2` is the sole
  entry; Agent declares `EzagentDomainInstanceMessage.AgentSupervisor` via its
  `supervisor/0` callback.)

  This is the realization of memory `feedback_north_star_plugin_isolation`:
  the Agent module knows nothing about bridges; the bridge plugin
  knows nothing about Chat internals. `Ezagent.Kind.spawn/2` +
  `Ezagent.Kind.Server` are the only contact points, and they're both
  `ezagent_core` machinery.

  ## URI shape (PR #141 SPEC v2)

  Bridges supply `agent_uri` either via the mcp.json `env` field
  (preferred — PtyServer writes it deterministically) or via
  `EZAGENT_AGENT_URI` operator-shell env (legacy fallback). The
  canonical shape is `entity://agent/<flavor>_<name>` per SPEC §5.14
  (flavor in name prefix); anything matching `entity://agent/*` works
  at the routing layer.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :agent

  # Phase 3d: Agent carries Identity Behavior alongside Chat. Default
  # initial_caps is empty (Agent has no authority to initiate; chat
  # receive only). Operators can grant caps via Identity invoke if
  # they want to elevate a specific Agent.
  #
  # PR2 2026-05-24 (Allen): Sandbox Behavior added — per-agent
  # config_dir_path + Kind.Template plugin extension callbacks. Empty
  # by default (no FS dir until a Template Class's `create_config_dir/2`
  # is called at spawn).
  #
  # Allen 2026-05-26: ApiKeys Behavior moved from User Kind to here —
  # agents hold their OWN outbound credentials (the credential funds
  # the agent's outbound HTTP call). `:api_keys` slice carries
  # `:creator_uri` populated at instantiate so `data_owner/1` knows
  # who can rotate. CapabilityRegistry binding lives in
  # `EzagentDomainIdentity.Application` against `Ezagent.Entity.Agent`
  # — same cross-domain pattern as Identity Behavior registration.
  @impl Ezagent.Kind
  def behaviors,
    do: [
      Ezagent.Behavior.Chat,
      Ezagent.Behavior.Identity,
      Ezagent.Behavior.Sandbox,
      Ezagent.Behavior.ApiKeys,
      Ezagent.Behavior.CredentialGrant
    ]

  # Allen 2026-05-25 — bumped from `:on_terminate` to `{:snapshot, :on_change}`
  # as part of the CLI persistence fix (PR codex r1 HIGH).
  #
  # Original Phase 4-completion Spec 04 choice was `:on_terminate` with
  # the note "Bump to `:on_change` in Phase 5 once Agent caps see real
  # promotion volume." That bump is now required because the CLI flow
  # `mix ezagent.agent.create … --caps …`:
  #
  #   1. spawns the Agent (Kind init writes initial empty-identity slice)
  #   2. dispatches `grant_initial_caps` (mutates identity slice)
  #   3. mix BEAM exits before `terminate/2` reliably drains
  #
  # Under `:on_terminate`, step 2's mutation is `:not_durable` in
  # `Snapshot.commit/4` and step 3 races terminate against halt. Result:
  # the DB row holds the pre-grant slice and the caps appear to vanish
  # on next BEAM. Under `:on_change`, step 2 writes synchronously; the
  # caps are durable before `mix` returns.
  #
  # Trade-off: one extra ~1ms SQLite write per dispatch that mutates
  # Agent's slice. Identity mutations are operator-initiated cap
  # grants (rare), and Chat slice mutations were already the dominant
  # write volume on the same DB.
  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  # V1 prevention (Allen 2026-05-21): Agent Kinds (including Echo —
  # chat's `spawn_agent/1` flavor-resolver routes echo here too) live
  # under the chat domain's AgentSupervisor. `Ezagent.Kind.spawn/2`
  # reads this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainInstanceMessage.AgentSupervisor

  @doc """
  Phase 7 PR 40 — Spawn a worker agent from an AgentTemplate.

  Composes existing primitives without introducing a new spawn
  contract: builds the instance Agent URI, calls
  `Ezagent.SpawnRegistry.spawn/1` (URI-only per Decision #65), then
  records lineage in `Ezagent.WorkspaceRegistry` for workspace scope +
  `Ezagent.AgentLineage` for `{:spawned_by, _}` cap resolution (PR 42
  / Decision #137).

  ## Args

  - `template_uri` — `template://agent/<template_name>` (must
    be an already-registered AgentTemplate Kind)
  - `instance_name` — string, becomes the instance Agent URI's
    name segment (`entity://agent/<instance_name>` — PR #141 SPEC v2;
    caller supplies the full flavor-prefixed name like `cc_<id>`).
    Caller's job to ensure uniqueness; collisions return
    `{:error, {:already_started, _}}` per SpawnRegistry semantics.
  - `workspace_uri` — `%URI{}` scope this Agent belongs to;
    bound via `Ezagent.WorkspaceRegistry.bind/2` so workspace-scoped
    routing rules apply (invariant 4 per esr-developer skill).
  - `granted_by` — `%URI{}` of the principal authorizing the spawn
    (orchestrator URI in the typical case). Recorded in
    `Ezagent.AgentLineage` to support `{:spawned_by, granted_by}`
    scoped delegation caps.

  ## Return

  `{:ok, agent_uri}` on success, `{:error, reason}` on spawn or
  lineage-record failure. Lineage failure (registry not started)
  is logged but not fatal — the agent spawns successfully and
  loses lineage tracking only.

  ## What this PR does NOT do

  - Does NOT instantiate the underlying claude process (PtyServer
    spawns that on bridge announce). AgentTemplate's
    `project_cwd` / `config_dir` / `settings_path`
    are consumed by the PR 32 v2 bridge / PtyServer integration —
    Agent.spawn/4 is the ESR-side Kind registration, not the
    PTY-side process spawn.
  - Does NOT populate AgentTemplate slice content from the
    template Kind (the template's slice is empty per PR 37 — admin
    populates it). Calling Agent.spawn/4 against an empty
    AgentTemplate produces an Agent with default settings (operator
    `~/.claude/`).
  """
  @spec spawn(
          template_uri :: URI.t(),
          instance_name :: String.t(),
          workspace_uri :: URI.t(),
          granted_by :: URI.t()
        ) :: {:ok, URI.t()} | {:error, term()}
  def spawn(%URI{} = template_uri, instance_name, %URI{} = workspace_uri, %URI{} = granted_by)
      when is_binary(instance_name) do
    # Generator-reconciler PR-A — `spawn/4` is now a thin shim over the
    # new `spawn_fresh/4` primitive. The legacy contract — return
    # `{:ok, agent_uri}` after binding workspace + recording lineage,
    # regardless of whether the worker was freshly created or adopted —
    # is preserved BY UNCONDITIONALLY recording lineage + binding on
    # both `:fresh?` outcomes. Reconciler callers MUST use `spawn_fresh/4`
    # directly (so they can re-enter the ownership gate on `fresh?: false`
    # instead of silently re-parenting a foreign worker — codex rev-4
    # HIGH-1). Non-reconciler callers (test fixtures, future legacy
    # paths) keep the old behaviour through this shim.
    case spawn_fresh(template_uri, instance_name, workspace_uri, granted_by) do
      {:ok, %{pid: _pid, fresh?: true, agent_uri: agent_uri}} ->
        {:ok, agent_uri}

      {:ok, %{pid: _pid, fresh?: false, agent_uri: agent_uri}} ->
        # Legacy shim contract: an adopted worker still gets re-bound +
        # re-lineaged so the call returns the same `{:ok, agent_uri}`
        # shape pre-PR-A callers expect. This is the TOCTOU window
        # callers using `spawn_fresh/4` directly avoid.
        with :ok <- Ezagent.WorkspaceRegistry.bind(agent_uri, workspace_uri),
             :ok <- record_lineage(agent_uri, granted_by) do
          {:ok, agent_uri}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Generator-reconciler PR-A (SPEC §2 step 2 + §5, codex rev-4 HIGH-1) —
  the SIDE-EFFECT-FREE-ON-`:already_started` spawn primitive.

  `spawn_fresh/4` performs `SpawnRegistry.spawn_detailed/1` and:

    * for `:started` (THIS call won the supervisor start) — records
      lineage + binds workspace, returns `{:ok, %{pid, fresh?: true,
      agent_uri}}`;
    * for `:already_started` (the URI was live before this call) —
      records NOTHING, returns `{:ok, %{pid, fresh?: false, agent_uri}}`.
      No `WorkspaceRegistry.bind`, no `AgentLineage.record`. The caller
      decides what to do with the existing process (re-enter an
      ownership gate, refuse to adopt, etc.).
    * on a spawn error — `{:error, term()}`.

  Reconciler use: the orchestrator-ensure step (SPEC §2 step 2) calls
  `spawn_fresh/4` and on `fresh?: false` re-enters its ownership gate
  rather than silently re-parenting a foreign process at the same URI.
  """
  @spec spawn_fresh(URI.t(), String.t(), URI.t(), URI.t()) ::
          {:ok, %{pid: pid(), fresh?: boolean(), agent_uri: URI.t()}} | {:error, term()}
  def spawn_fresh(
        %URI{} = _template_uri,
        instance_name,
        %URI{} = workspace_uri,
        %URI{} = granted_by
      )
      when is_binary(instance_name) do
    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)

    agent_uri = Ezagent.URI.agent(workspace_name, instance_name)

    case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
      {:ok, :started, pid} ->
        with :ok <- Ezagent.WorkspaceRegistry.bind(agent_uri, workspace_uri),
             :ok <- record_lineage(agent_uri, granted_by) do
          {:ok, %{pid: pid, fresh?: true, agent_uri: agent_uri}}
        end

      {:ok, :already_started, pid} ->
        # ZERO side effects on already-started — preserves the TOCTOU
        # avoidance contract (codex rev-4 HIGH-1). The caller decides.
        {:ok, %{pid: pid, fresh?: false, agent_uri: agent_uri}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  The shared session-unique LIVE worker instance name (Phase 7
  completion hardening — CRITICAL + HIGH-6).

  ## The bug this closes

  Worker instance URIs are deterministic from `{workspace, flavor,
  instance_name}`. The pre-hardening Generator + `add_agent_slot`
  passed the **bare slot name** as `instance_name` for every
  `template.instantiate`. Two sessions instantiated from the SAME
  SessionTemplate therefore got the SAME live worker URI for a slot —
  the cc Class treats an already-started worker as idempotent success,
  and `AgentLineage.record/2` (an ETS *set*) lets the later session
  silently OVERWRITE the worker's parent lineage. Session isolation
  breaks: the prior session loses cap #2, and routing / PTY state is
  shared between two unrelated sessions. The same determinism made
  `update_agent_template` a no-op for a same-flavor swap — old + new
  worker URIs were equal, so the worker never restarted.

  ## The fix

  The LIVE worker instance name is made **session-unique** by folding
  in a `session_discriminator` (the generated Session's name segment)
  and an optional `generation` counter (incremented on every
  `update_agent_template` swap of the same slot). The durable
  `template_working_copy` SLOT name stays the bare `slot_name` — it is
  the template-shaped key, stable across instantiations; only the
  live instance URI gets uniqueness.

  Result: `<slot>-<8hex>--<session_discriminator>` (generation 0) or
  `<slot>-<8hex>--<session_discriminator>--g<n>` (generation ≥ 1). Two
  sessions from one template → disjoint live worker URIs; a same-flavor
  `update_agent_template` → a fresh generation-specific URI, so the
  worker actually restarts.

  ## MEDIUM-5 (hardening round 2) — the slot component is INJECTIVE

  `sanitize_segment/1` collapses every char outside `[a-zA-Z0-9_-]` to
  `-`, so two DISTINCT slot names — `api.v1` and `api-v1` — sanitized
  to the SAME `api-v1` and produced the SAME instance name. The second
  spawn in that session then re-used the first slot's worker URI. The
  encoded slot component is made injective by appending a hex slice of
  `:crypto.hash(:sha256, original_slot_name)` — computed over the
  ORIGINAL (un-sanitized) slot string, so distinct inputs hash
  distinctly even when their sanitized forms collide. The session
  discriminator does NOT need the hash (it is already globally unique —
  `gen-<millis>-<unique_int>`).

  ## MEDIUM-3 (hardening round 3) — the digest is widened to 32 hex

  Round 2 appended only the FIRST 8 hex chars of the SHA-256 digest —
  a 32-bit collision domain. Two distinct slot names whose sanitized
  forms ALSO collide need only a 32-bit hash collision to produce the
  same instance name (and hence the same worker URI). The digest is now
  the first **32 hex chars** (128 bits) — accidental collision is
  negligible. This is the probabilistic defense; the deterministic
  guarantee is **per-session `role_name` uniqueness** (enforced at
  `chat.join` by `Ezagent.Behavior.Chat`'s `role_name_conflict/3`,
  team-routing-unification §3.1) — two members in one session cannot share
  a role_name, and the session discriminator folded into the name keeps
  distinct sessions distinct. (The pre-§3.8 slot-tool
  `Ezagent.Orchestrator.SlotNames` up-front-collision preflight was
  retired with the slot mechanism — clean cutover.)
  """
  @spec session_instance_name(String.t(), String.t(), non_neg_integer()) :: String.t()
  def session_instance_name(slot_name, session_discriminator, generation \\ 0)
      when is_binary(slot_name) and is_binary(session_discriminator) and
             is_integer(generation) and generation >= 0 do
    disc = sanitize_segment(session_discriminator)
    # MEDIUM-3/MEDIUM-5 — the sanitized slot label may collide for
    # distinct slot names; the appended wide hash of the ORIGINAL name
    # restores injectivity with a negligible collision domain.
    slot_component = "#{sanitize_segment(slot_name)}-#{slot_hash(slot_name)}"
    base = "#{slot_component}--#{disc}"

    if generation == 0 do
      base
    else
      "#{base}--g#{generation}"
    end
  end

  # MEDIUM-3 — the slot-hash width. 32 hex chars = 128 bits of the
  # SHA-256 digest. Folded into the instance-name slot component so two
  # slot names whose sanitized forms collide (`api.v1` / `api-v1`) get
  # DISTINCT instance names. Round 2 used 8 (a 32-bit domain); widened
  # here so accidental collision is negligible.
  @slot_hash_hex_width 32

  # MEDIUM-3/MEDIUM-5 — a stable, collision-resistant hex fingerprint of
  # the ORIGINAL (un-sanitized) slot name. Stable across runs (pure
  # `:crypto.hash`), URI-safe (hex only).
  defp slot_hash(slot_name) when is_binary(slot_name) do
    :sha256
    |> :crypto.hash(slot_name)
    |> Base.encode16(case: :lower)
    |> binary_part(0, @slot_hash_hex_width)
  end

  # URI name segments must be filesystem/URI-safe — collapse anything
  # outside `[a-zA-Z0-9_-]` to `-` so a slot name or session
  # discriminator with spaces / dots cannot break the instance URI.
  defp sanitize_segment(seg) when is_binary(seg) do
    seg
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
    |> case do
      "" -> "x"
      s -> s
    end
  end

  @doc """
  Phase 7 completion PR-1 (SPEC §1.6a) — spawn a worker agent from an
  AgentTemplate's `:template` slice CONTENT, delegating the launch to
  the flavor's plugin Template Class and re-establishing the post-spawn
  obligations (lineage + workspace binding) the Class does not perform.

  This is the **content-taking** spawn helper. It takes the template
  content as an ARGUMENT — it does NOT dispatch `:read` (the
  `Ezagent.Behavior.Template` `:instantiate` action that calls it is
  ALREADY running inside the AgentTemplate Kind process with the slice
  in hand; a `:read` self-dispatch would be a `GenServer.call(self)`
  deadlock — codex rev-5 HIGH-2).

  ## Contract (SPEC §1.6a)

  1. **Look up the Class** — from `content.flavor`,
     `Ezagent.AgentFlavorRegistry.lookup/1` → `%{template_class: tc}`.
  2. **Build the Class data map** — `AgentTemplate.to_template_data/2`
     (§1.5 adapter) from the content + `instance_uri`.
  3. **Delegate the launch** — `tc.instantiate(tc.template_name(),
     data, workspace_uri)` → `{:ok, [worker_uri]}` (the plugin owns
     exactly this — the Agent Kind + PTY).
  4. **Record lineage (helper-owned, fresh-only)** — for each returned
     `worker_uri`, `Ezagent.AgentLineage.record(worker_uri,
     spawned_by_uri)`. The plugin Template Class does NOT do this, so
     cap #2 (`{:spawned_by, orchestrator}`) would never resolve without
     this step. Runs ONLY when `fresh?: true` (see codex round-7 below).
  5. **Bind workspace (helper-owned, fresh-only)** — for each
     `worker_uri`, `Ezagent.WorkspaceRegistry.bind(worker_uri,
     workspace_uri)` (invariant 4 — workspace-scoped routing rules must
     fire). Runs ONLY when `fresh?: true` (see codex round-7 below).

  NO `:read` dispatch anywhere.

  ## Args

  - `template_content_map` — the AgentTemplate `:template` slice content
    (carries `flavor`, `project_cwd`, the sandbox keys incl. `config_dir`).
  - `instance_uri` — the per-instance agent URI the caller built.
  - `spawned_by_uri` — `%URI{}` of the principal authorizing the spawn
    (the owner for the orchestrator agent; the orchestrator's own URI
    for `add_agent_slot` workers, so cap #2 resolves).
  - `workspace_uri` — `%URI{}` scope the worker belongs to.

  ## Return — the fresh-vs-adopted signal (codex round-5 MEDIUM-3, round-6 HIGH-1)

  `{:ok, %{workers: [worker_uri], fresh?: boolean()}}` on success,
  `{:error, reason}` otherwise.

  Every plugin `Ezagent.Kind.Template` `instantiate/3` is documented as
  IDEMPOTENT — re-calling after the Kinds are alive is a no-op that
  returns the SAME URIs. That idempotency is correct for the
  Workspace.Loader boot path, but it must not ERASE a signal
  `update_agent_template` needs: did THIS call freshly create the
  worker, or did it adopt a pre-existing one? (A concurrent spawn
  registering the candidate URI → `instantiate` silently adopts a
  worker the swap did NOT create; `record_lineage`/`bind_workspace`
  then mutate ownership for an adopted worker.)

  ## codex round-6 HIGH-1 — `fresh?` comes from the ATOMIC spawn result

  Round 5 reconstructed `fresh?` by probing `KindRegistry` for
  `instance_uri` BEFORE delegating to `template_class.instantiate/3`.
  That probe is a TOCTOU window: a concurrent registration BETWEEN the
  probe and the plugin's spawn makes an adopted worker read as fresh.

  Round 6 removes the window structurally. `Ezagent.Kind.Template`
  `instantiate/3` now returns the 3-element `{:ok, [URI.t()], %{fresh?:
  boolean()}}` form, where `fresh?` is derived from the ATOMIC
  `DynamicSupervisor.start_child` outcome (`SpawnRegistry.spawn_detailed/1`
  preserves `:started` vs `:already_started`) — exactly one concurrent
  caller wins the start. `spawn_from_template_content/4` reads `fresh?`
  from THAT result. No pre-probe; the check+spawn is atomic, so the
  window is removed, not narrowed.

  A Template Class returning the legacy 2-element `{:ok, [URI.t()]}`
  form supplies no `fresh?` — it is treated conservatively as `false`
  (the swap then errs on the side of refusing a possible adoption).

  ## codex round-7 HIGH-1 — side effects gated on `fresh?: true`

  Round 6 made `fresh?` an ATOMIC signal but still recorded lineage and
  bound the workspace for EVERY returned worker, BEFORE the caller saw
  `fresh?`. `AgentLineage.record/2` is an ETS set insert that OVERWRITES
  the worker's `spawned_by`, and `WorkspaceRegistry.bind/2` OVERWRITES
  the binding. So a `fresh?: false` worker — one created by some other
  operation, which `instantiate` merely ADOPTED — got re-parented under
  THIS orchestrator (its `{:spawned_by, orchestrator}` cap then matched!)
  and workspace-rebound, even though `update_agent_template` then
  correctly refused the adoption (`:candidate_uri_already_live`). The
  "safe-degraded" abort was not actually side-effect-free.

  Round 7 gates the post-spawn obligations on `fresh?: true` — a worker
  THIS call created. A `fresh?: false` result is returned with the
  worker URI and ZERO side effects: the pre-existing worker's lineage +
  workspace binding are left exactly as they were. The swap's
  `:candidate_uri_already_live` abort is now genuinely side-effect-free.

  ## codex round-10 HIGH-2 — a post-spawn failure undoes the fresh spawn

  Round 7 ran the post-spawn obligations as `:ok = record_lineage(...)`
  / `:ok = bind_workspace(...)`. A `bind_workspace/2` failure AFTER a
  successful `record_lineage/2` would (a) RAISE on the `:ok =` match —
  an exception, not a clean `{:error, _}` — and (b) leave the freshly
  created worker with a lineage row but no workspace binding: residue
  the caller could not see or clean.

  Round 10 makes this helper own its own partial-spawn teardown. The
  obligations run as a CHECKED step (`establish_post_spawn_obligations/3`);
  on ANY failure after the plugin Template Class freshly created the
  worker, this helper undoes everything IT established for that worker —
  terminate the Kind, forget the lineage row, unbind the workspace
  (`undo_fresh_workers/1`) — and returns a clean `{:error, reason}`. A
  fresh `spawn_from_template_content/4` therefore either fully succeeds
  or leaves ZERO residue: combined with the plugin Template Class
  cleaning up its own freshly-started-then-failed Kind (cc/echo round
  10), a per-slot instantiate is all-or-nothing, so the Generator's
  `instantiate_agent_slots/4` `acc`-only accumulator (round 9) is
  correct — a failed slot has already self-cleaned.
  """
  @spec spawn_from_template_content(map(), URI.t(), URI.t(), URI.t()) ::
          {:ok,
           %{
             :workers => [URI.t()],
             :fresh? => boolean(),
             optional(:role_degraded) => boolean(),
             optional(:role_degraded_reason) => term()
           }}
          | {:error, term()}
  def spawn_from_template_content(
        template_content_map,
        %URI{} = instance_uri,
        %URI{} = spawned_by_uri,
        %URI{} = workspace_uri
      ) do
    spawn_from_template_content(
      template_content_map,
      instance_uri,
      spawned_by_uri,
      workspace_uri,
      []
    )
  end

  def spawn_from_template_content(_content, _instance, _spawned_by, _workspace) do
    {:error, :invalid_spawn_from_template_content_args}
  end

  @doc false
  @spec spawn_from_template_content(map(), URI.t(), URI.t(), URI.t(), keyword()) ::
          {:ok,
           %{
             :workers => [URI.t()],
             :fresh? => boolean(),
             optional(:role_degraded) => boolean(),
             optional(:role_degraded_reason) => term()
           }}
          | {:error, term()}
  def spawn_from_template_content(
        template_content_map,
        %URI{} = instance_uri,
        %URI{} = spawned_by_uri,
        %URI{} = workspace_uri,
        opts
      )
      when is_map(template_content_map) and is_list(opts) do
    with {:ok, template_class} <-
           EzagentDomainInstanceMessage.SessionCreator.TemplateResolver.resolve_template_class(
             template_content_map
           ),
         {:ok, flavor} <- template_content_flavor(template_content_map),
         {:ok, template_content_map} <-
           resolve_cascade_content(
             template_content_map,
             template_class,
             instance_uri,
             spawned_by_uri,
             workspace_uri,
             flavor,
             opts
           ),
         {:ok, data} <-
           Ezagent.Entity.AgentTemplate.to_template_data(template_content_map, instance_uri),
         :ok <- Ezagent.AgentFlavorAttributes.put(instance_uri, flavor),
         {:ok, workers, fresh?, instantiate_meta} <-
           instantiate_workers(template_class, data, workspace_uri) do
      instantiate_meta = put_respawn_flavor(instantiate_meta, template_content_map)

      # codex PR #408 review HIGH-3 — surface role-bootstrap degradation
      # from the plugin Template Class's instantiate meta. The plugin
      # (cc) attaches `:role_degraded` + `:role_degraded_reason` keys to
      # its meta when an orchestrator skill-bootstrap step failed but
      # the agent itself was still spawned successfully. We propagate
      # them so the orchestrator-aware caller (Session.ensure_orchestrator)
      # can notify the session owner per Invariant #9.
      role_degraded_passthrough =
        instantiate_meta
        |> Map.take([:role_degraded, :role_degraded_reason])
        |> case do
          map when map_size(map) == 0 -> %{}
          map -> map
        end

      # codex round-7 HIGH-1 — the post-spawn obligations (lineage +
      # workspace binding) are side effects that OVERWRITE existing rows:
      # `AgentLineage.record/2` is an ETS set insert (re-parents the
      # worker under `spawned_by_uri`) and `WorkspaceRegistry.bind/2`
      # overwrites the binding. They must run ONLY for a worker THIS call
      # actually created — `fresh?: true`.
      #
      # When `fresh?: false`, the instantiate ADOPTED a pre-existing
      # worker (one created by some other operation — e.g. a concurrent
      # spawn). Recording lineage / binding workspace for it would
      # re-parent a worker this call did NOT create. `update_agent_template`
      # then correctly refuses the adoption (`require_fresh_candidate/1` →
      # `:candidate_uri_already_live`), but the damage would already be
      # done. So a `fresh?: false` result returns the worker URI with
      # ZERO side effects — the pre-existing worker's lineage + workspace
      # binding are left exactly as they were, making the swap's abort
      # genuinely side-effect-free.
      # codex round-10 HIGH-2 — the post-spawn obligations are now a
      # CHECKED step that self-cleans on failure. Pre-round-10 this was
      # `:ok = record_lineage(...)` / `:ok = bind_workspace(...)` — if
      # `bind_workspace/2` failed AFTER `record_lineage/2` succeeded, the
      # `:ok =` match RAISED (an exception, not a clean `{:error, _}`)
      # and left a worker that the plugin Template Class freshly created
      # WITH a lineage row but WITHOUT a workspace binding — a residue
      # the caller could not see. Now: if a step AFTER the fresh spawn
      # fails, `spawn_from_template_content/4` undoes everything IT
      # established for the worker it created — terminate the Kind
      # (`Ezagent.Kind.terminate/1`), forget the lineage row, unbind the
      # workspace — and returns a clean `{:error, reason}`. A fresh
      # instantiate therefore either fully succeeds or leaves ZERO
      # residue. (`fresh?: false` adopts a pre-existing worker — no
      # obligations run, nothing to undo — round 7.)
      if fresh? do
        # PR3 2026-05-24 — `record_sandbox_state/3` is a NEW CHECKED step
        # after post-spawn obligations: dispatches `sandbox.write_path`
        # on each worker so its `:sandbox` slice carries the per-agent
        # config_dir + template_class. Without this, a destroy_config_dir
        # callback later cannot know what to clean up.
        #
        # A failure here triggers `undo_fresh_workers/1` (same Round-10
        # rollback as a post-spawn-obligation failure): terminate the
        # worker, unbind workspace, forget lineage, AND (cc-specific)
        # the plugin's own `rollback_agent_config_dir` already ran
        # inside `instantiate/3` if PTY failed there. Here we additionally
        # delete the dir we just created if the write_path dispatch
        # itself fails — otherwise the agent terminates but the dir
        # leaks because `Sandbox.invoke(:destroy, ...)` would never run
        # (the agent never even came up).
        with :ok <- establish_post_spawn_obligations(workers, spawned_by_uri, workspace_uri),
             :ok <- record_sandbox_state(workers, instantiate_meta, template_class) do
          {:ok, Map.merge(%{workers: workers, fresh?: fresh?}, role_degraded_passthrough)}
        else
          {:error, reason} ->
            undo_fresh_workers(workers)
            cleanup_partial_config_dirs(workers, template_class)
            {:error, reason}
        end
      else
        # `fresh?: false` — adopted a pre-existing worker. Still
        # write_path so its slice reflects the (already-existing)
        # config_dir, but don't roll back on failure (we didn't create
        # the worker).
        _ = record_sandbox_state(workers, instantiate_meta, template_class)
        {:ok, Map.merge(%{workers: workers, fresh?: fresh?}, role_degraded_passthrough)}
      end
    end
  end

  def spawn_from_template_content(_content, _instance, _spawned_by, _workspace, _opts) do
    {:error, :invalid_spawn_from_template_content_args}
  end

  defp template_content_flavor(template_content_map) when is_map(template_content_map) do
    case Map.get(template_content_map, :flavor) || Map.get(template_content_map, "flavor") do
      flavor when is_binary(flavor) and flavor != "" -> {:ok, flavor}
      _ -> {:error, :missing_flavor}
    end
  end

  # #17 cascade PR-3 — activate PR-2's layered file materializer at the domain spawn
  # bridge. Callers may provide the durable resolution INPUTS under `cascade_resolution`;
  # this bridge resolves them immediately before the Template Class sees data, so normal
  # spawn paths do not need to hand-author `tmpl["cascade"]`.
  defp resolve_cascade_content(
         content,
         template_class,
         agent_uri,
         spawned_by_uri,
         workspace_uri,
         flavor,
         opts
       )
       when is_map(content) do
    cond do
      is_map(content_field(content, :cascade)) ->
        {:ok, content}

      is_map(content_field(content, :cascade_resolution)) ->
        with {:ok, cascade, resolved} <-
               build_cascade(
                 content_field(content, :cascade_resolution),
                 agent_uri,
                 spawned_by_uri,
                 workspace_uri,
                 flavor
               ),
             {:ok, _grant} <-
               maybe_mint_cascade_grant(
                 agent_uri,
                 resolved.secret_source,
                 opts,
                 content_field(content, :cascade_resolution)
               ) do
          content =
            content
            |> Map.put(:cascade, cascade)
            |> put_selected_credential_source(resolved.secret_source)

          {:ok, content}
        end

      is_nil(content_field(content, :cascade_resolution)) ->
        maybe_resolve_default_cascade_content(
          content,
          template_class,
          agent_uri,
          spawned_by_uri,
          workspace_uri,
          flavor,
          opts
        )

      true ->
        {:error, {:invalid_cascade_resolution, content_field(content, :cascade_resolution)}}
    end
  end

  defp maybe_resolve_default_cascade_content(
         content,
         template_class,
         agent_uri,
         spawned_by_uri,
         workspace_uri,
         flavor,
         opts
       ) do
    source_template_uri = Keyword.get(opts, :source_template_uri)
    credential_adapter = credential_adapter_kind(template_class)

    if credential_adapter != :none and
         match?(%URI{}, source_template_uri) and
         default_cascade_configured?(credential_adapter, content, source_template_uri) do
      resolution = %{
        owner_uri: spawned_by_uri,
        workspace_uri: workspace_uri,
        workspace_layer_uri: source_template_uri,
        flavor: flavor,
        credential_required?: credential_required_by_default?(credential_adapter),
        explicit_source: Keyword.get(opts, :explicit_source)
      }

      with {:ok, cascade, resolved} <-
             build_cascade(resolution, agent_uri, spawned_by_uri, workspace_uri, flavor),
           {:ok, content} <-
             put_default_cascade_if_source_present(
               content,
               cascade,
               resolved,
               agent_uri,
               opts,
               resolution
             ) do
        {:ok, content}
      end
    else
      {:ok, content}
    end
  end

  defp put_default_cascade_if_source_present(
         content,
         _cascade,
         %{secret_source: nil},
         _agent,
         _opts,
         _resolution
       ) do
    {:ok, content}
  end

  defp put_default_cascade_if_source_present(
         content,
         cascade,
         %{secret_source: source},
         agent_uri,
         opts,
         resolution
       ) do
    with {:ok, _grant} <- maybe_mint_cascade_grant(agent_uri, source, opts, resolution) do
      content =
        content
        |> Map.put(
          :cascade_resolution,
          Map.put(resolution, :credential_source_uri, source)
        )
        |> Map.put(:cascade, cascade)

      {:ok, content}
    end
  end

  defp credential_adapter_kind(template_class) do
    cond do
      Ezagent.Agent.CredentialAdapter.credentialled?(template_class) -> :file
      Ezagent.Agent.CredentialSliceAdapter.credentialled?(template_class) -> :slice
      true -> :none
    end
  end

  defp credential_required_by_default?(:slice), do: true
  defp credential_required_by_default?(:file), do: false

  defp default_cascade_configured?(:slice, _content, %URI{}), do: true

  defp default_cascade_configured?(:file, content, %URI{} = source_template_uri) do
    case content_field(content, :config_dir) do
      dir when is_binary(dir) and dir != "" ->
        true

      _ ->
        case Ezagent.UriQuery.resolve(:config_dir, source_template_uri) do
          {:ok, dir} when is_binary(dir) and dir != "" -> true
          _ -> false
        end
    end
  end

  defp build_cascade(resolution, agent_uri, spawned_by_uri, workspace_uri, flavor) do
    with {:ok, layer_dir_for} <-
           cascade_function(resolution, :layer_dir_for, &default_layer_dir_for/1),
         {:ok, source_dir_for} <-
           cascade_function(resolution, :source_dir_for, &default_source_dir_for/1),
         {:ok, owner_uri} <-
           cascade_uri(resolution, :owner_uri, spawned_by_uri, required?: true),
         {:ok, resolved_workspace_uri} <-
           cascade_uri(resolution, :workspace_uri, workspace_uri, required?: false),
         {:ok, session_uri} <- cascade_uri(resolution, :session_uri, nil, required?: false),
         {:ok, explicit_source} <-
           cascade_uri(resolution, :explicit_source, nil, required?: false),
         {:ok, resolved} <-
           Ezagent.Credential.Resolver.resolve_layers(
             resolver_inputs(
               resolution,
               agent_uri,
               owner_uri,
               resolved_workspace_uri,
               session_uri,
               explicit_source,
               flavor
             )
           ),
         {:ok, layer_dirs} <- materializer_layer_dirs(resolved.config_layers, layer_dir_for) do
      {:ok, %{layer_dirs: layer_dirs, source_dir_for: source_dir_for}, resolved}
    end
  end

  defp cascade_function(resolution, key, default) do
    case Map.get(resolution, key) || Map.get(resolution, Atom.to_string(key)) do
      nil -> {:ok, default}
      fun when is_function(fun, 1) -> {:ok, fun}
      _ -> {:error, {:missing_cascade_resolution_function, key}}
    end
  end

  defp default_layer_dir_for(%{source: %URI{} = uri}) do
    case Ezagent.UriQuery.resolve(:config_dir, uri) do
      {:ok, dir} when is_binary(dir) -> {:ok, %{dir: dir, protected: [], mandatory: []}}
      :none -> :skip
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_layer_dir_for(_layer), do: :skip

  defp default_source_dir_for(%URI{} = source), do: default_config_dir_for_source(source)

  defp default_source_dir_for(source) when is_binary(source) do
    source
    |> Ezagent.URI.new!()
    |> default_config_dir_for_source()
  end

  defp default_config_dir_for_source(%URI{} = source) do
    case Ezagent.UriQuery.resolve(:config_dir, source) do
      {:ok, dir} when is_binary(dir) and dir != "" -> {:ok, dir}
      :none -> {:error, {:source_config_dir_absent, source}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_mint_cascade_grant(_agent_uri, nil, _opts, _resolution), do: {:ok, nil}

  defp maybe_mint_cascade_grant(%URI{} = agent_uri, %URI{} = source, opts, resolution) do
    caller = Keyword.get(opts, :caller)
    caps = Keyword.get(opts, :caps)

    result =
      cond do
        match?(%URI{}, caller) and is_list(caps) ->
          Ezagent.Credential.Resolver.authorize_and_mint_grant!(%{
            agent_uri: agent_uri,
            source: source,
            caller: caller,
            caps: caps
          })

        match?(%URI{}, caller) and match?(%MapSet{}, caps) ->
          Ezagent.Credential.Resolver.authorize_and_mint_grant!(%{
            agent_uri: agent_uri,
            source: source,
            caller: caller,
            caps: MapSet.to_list(caps)
          })

        true ->
          {:error, :missing_cascade_authorization}
      end

    case result do
      {:error, :missing_cascade_authorization} ->
        maybe_mint_workspace_shared_grant(agent_uri, source, caller, resolution)

      {:error, {:source_unauthorized, ^source}} ->
        maybe_mint_workspace_shared_grant(agent_uri, source, caller, resolution)

      other ->
        other
    end
  end

  defp maybe_mint_workspace_shared_grant(
         %URI{} = agent_uri,
         %URI{} = source,
         %URI{} = _caller,
         resolution
       ) do
    with nil <- Map.get(resolution, :explicit_source) || Map.get(resolution, "explicit_source"),
         {:ok, workspace_uri} <- cascade_uri(resolution, :workspace_uri, nil, required?: true),
         flavor when is_binary(flavor) <-
           Map.get(resolution, :flavor) || Map.get(resolution, "flavor"),
         true <-
           Ezagent.Capability.workspace_of(agent_uri) == Ezagent.Capability.workspace_of(source),
         %Ezagent.Credential.WorkspaceSharedSource{} = row <-
           Ezagent.Credential.WorkspaceSharedSource.get(URI.to_string(workspace_uri), flavor),
         true <- row.source_uri == URI.to_string(source),
         set_by when is_binary(set_by) and set_by != "" <- row.set_by do
      Ezagent.Credential.GrantRow.insert(%{
        agent_uri: URI.to_string(agent_uri),
        credential_source_uri: URI.to_string(source),
        approved_by: set_by,
        approved_scope: URI.to_string(source),
        version: 1
      })
    else
      _ -> {:error, {:source_unauthorized, source}}
    end
  end

  defp maybe_mint_workspace_shared_grant(_agent_uri, source, _caller, _resolution) do
    {:error, {:source_unauthorized, source}}
  end

  defp put_selected_credential_source(content, nil), do: content

  defp put_selected_credential_source(content, %URI{} = source) do
    key =
      if Map.has_key?(content, :cascade_resolution) do
        :cascade_resolution
      else
        "cascade_resolution"
      end

    case Map.get(content, key) do
      resolution when is_map(resolution) ->
        Map.put(content, key, Map.put(resolution, :credential_source_uri, source))

      _ ->
        content
    end
  end

  defp resolver_inputs(
         resolution,
         agent_uri,
         owner_uri,
         workspace_uri,
         session_uri,
         explicit_source,
         flavor
       ) do
    %{
      agent_uri: agent_uri,
      owner_uri: owner_uri,
      workspace_uri: workspace_uri,
      session_uri: session_uri,
      explicit_source: explicit_source,
      flavor: Map.get(resolution, :flavor) || Map.get(resolution, "flavor") || flavor,
      credential_required?: Map.get(resolution, :credential_required?, true)
    }
    |> maybe_put_uri_input(resolution, :workspace_layer_uri)
    |> maybe_put_uri_input(resolution, :user_layer_uri)
    |> maybe_put_uri_input(resolution, :session_layer_uri)
    |> maybe_put_resolver_fun(resolution, :source_available?)
    |> maybe_put_resolver_fun(resolution, :user_source_lookup)
    |> maybe_put_resolver_fun(resolution, :workspace_shared_lookup)
  end

  defp maybe_put_uri_input(inputs, resolution, key) do
    case Map.get(resolution, key) || Map.get(resolution, Atom.to_string(key)) do
      %URI{} = uri -> Map.put(inputs, key, uri)
      value when is_binary(value) and value != "" -> Map.put(inputs, key, Ezagent.URI.new!(value))
      _ -> inputs
    end
  end

  defp maybe_put_resolver_fun(inputs, resolution, key) do
    case Map.get(resolution, key) || Map.get(resolution, Atom.to_string(key)) do
      fun when is_function(fun) -> Map.put(inputs, key, fun)
      _ -> inputs
    end
  end

  defp materializer_layer_dirs(config_layers, layer_dir_for) do
    config_layers
    |> Enum.reduce_while({:ok, []}, fn layer, {:ok, acc} ->
      case layer_dir_for.(layer) do
        :skip ->
          {:cont, {:ok, acc}}

        nil ->
          {:cont, {:ok, acc}}

        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, dir} when is_binary(dir) ->
          {:cont, {:ok, acc ++ [%{dir: dir, protected: [], mandatory: []}]}}

        {:ok, %{dir: dir} = layer_dir} when is_binary(dir) ->
          {:cont, {:ok, acc ++ [normalize_layer_dir(layer_dir)]}}

        {:error, reason} ->
          {:halt, {:error, {:cascade_layer_dir_failed, layer, reason}}}

        other ->
          {:halt, {:error, {:invalid_cascade_layer_dir, layer, other}}}
      end
    end)
  end

  defp normalize_layer_dir(layer_dir) do
    layer_dir
    |> Map.put_new(:protected, [])
    |> Map.put_new(:mandatory, [])
  end

  defp cascade_uri(resolution, key, default, required?: required?) do
    case Map.get(resolution, key) || Map.get(resolution, Atom.to_string(key)) || default do
      %URI{} = uri -> {:ok, uri}
      s when is_binary(s) and s != "" -> {:ok, Ezagent.URI.new!(s)}
      nil when not required? -> {:ok, nil}
      nil -> {:error, {:missing_cascade_resolution_uri, key}}
    end
  end

  defp content_field(content, key) when is_atom(key) do
    case Map.get(content, key) do
      nil -> Map.get(content, Atom.to_string(key))
      v -> v
    end
  end

  @doc false
  def sanitize_respawn_template_data(respawn_data, template_content)
      when is_map(respawn_data) and is_map(template_content) do
    respawn_data
    |> Map.drop(["cascade", :cascade])
    |> put_respawn_cascade_resolution(template_content)
  end

  def sanitize_respawn_template_data(respawn_data, _template_content), do: respawn_data

  defp put_respawn_cascade_resolution(respawn_data, template_content) do
    case content_field(template_content, :cascade_resolution) do
      resolution when is_map(resolution) ->
        case cascade_resolution_snapshot(resolution) do
          snapshot when map_size(snapshot) > 0 ->
            Map.put(respawn_data, "cascade_resolution", snapshot)

          _ ->
            respawn_data
        end

      _ ->
        respawn_data
    end
  end

  defp cascade_resolution_snapshot(resolution) do
    [
      :owner_uri,
      :workspace_uri,
      :session_uri,
      :explicit_source,
      :credential_source_uri,
      :workspace_layer_uri,
      :user_layer_uri,
      :session_layer_uri
    ]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(resolution, key) || Map.get(resolution, Atom.to_string(key)) do
        %URI{} = uri -> Map.put(acc, Atom.to_string(key), uri_to_respawn_value(uri))
        value when is_binary(value) and value != "" -> Map.put(acc, Atom.to_string(key), value)
        _ -> acc
      end
    end)
  end

  defp uri_to_respawn_value(%URI{} = uri), do: URI.to_string(uri)

  defp put_respawn_flavor(meta, template_content_map) when is_map(meta) do
    case Map.get(template_content_map, :flavor) || Map.get(template_content_map, "flavor") do
      flavor when is_binary(flavor) and flavor != "" ->
        case Map.get(meta, :respawn_template_data) do
          data when is_map(data) ->
            respawn_data =
              data
              |> sanitize_respawn_template_data(template_content_map)
              |> Map.put_new("flavor", flavor)

            Map.put(meta, :respawn_template_data, respawn_data)

          _ ->
            meta
        end

      _ ->
        meta
    end
  end

  # codex round-6 HIGH-1 + PR3 2026-05-24 — call the plugin Template
  # Class's `instantiate/3` and normalize its return to `{:ok, workers,
  # fresh?, meta}`. The 3-element `{:ok, workers, %{fresh?:, ...}}`
  # form carries the atomic fresh-vs-adopted signal AND any
  # plugin-supplied PR3-style per-spawn metadata (e.g.
  # `:config_dir_path` for cc). The legacy 2-element `{:ok, workers}`
  # form has no signal — `fresh?` defaults conservatively to `false`
  # and meta is an empty map.
  defp instantiate_workers(template_class, data, %URI{} = workspace_uri) do
    # PR-3 (domain.agent D2) — route through the core contract-boundary wrapper so
    # the per-agent config_dir TARGET is domain-allocated + provided as data
    # (`"allocated_config_dir"`) before the plugin materializes into it.
    case Ezagent.Kind.Template.provision_and_instantiate(
           template_class,
           template_class.template_name(),
           data,
           workspace_uri
         ) do
      {:ok, workers, meta} when is_list(workers) and is_map(meta) ->
        {:ok, workers, Map.get(meta, :fresh?, false) == true, meta}

      {:ok, workers} when is_list(workers) ->
        {:ok, workers, false, %{}}

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_instantiate_result, other}}
    end
  end

  # PR3 2026-05-24 — dispatch `sandbox.write_path` on each worker URI
  # so the agent's `:sandbox` slice carries the per-agent
  # `config_dir_path` + `template_class`. Both fields are needed by
  # `Sandbox.invoke(:destroy, ...)` to invoke the right cleanup callback
  # with the right path.
  #
  # Codex PR3 round-2 HIGH-1 — SKIP dispatch entirely when meta lacks
  # `:config_dir_path`. The :already_started loser path returns no
  # config_dir_path; if we still dispatched, we'd write `nil` into the
  # slice and CLOBBER the live state the :started winner just populated.
  # The result would be a slice with no path → destroy_config_dir would
  # never run → credential dir leaks.
  #
  # When meta carries :config_dir_path = nil EXPLICITLY (a plugin that
  # opted out of per-agent dirs, e.g. echo template returning
  # %{config_dir_path: nil}), we DO dispatch — recording that the
  # template_class manages no dir is a meaningful state. The "missing
  # key" vs "explicit nil" distinction is the gate.
  defp record_sandbox_state(workers, meta, template_class) do
    if Map.has_key?(meta, :config_dir_path) do
      do_record_sandbox_state(
        workers,
        Map.get(meta, :config_dir_path),
        template_class,
        # PTY-orphan-restart 2026-05-26 — the plugin Template Class
        # may also emit `:respawn_template_data` in meta (cc does;
        # echo doesn't). Passed through to `sandbox.write_path` so
        # the slice carries enough state for `Sandbox.post_init/2` to
        # respawn the subprocess on a phx restart. Absent in meta →
        # `nil` here → not written into the slice.
        Map.get(meta, :respawn_template_data)
      )
    else
      # Loser/short-circuit path: meta has no :config_dir_path → don't
      # touch the slice (it was populated by the winner OR was already
      # in the right state). No-op = safe.
      :ok
    end
  end

  defp do_record_sandbox_state(workers, config_dir, template_class, respawn_data) do
    Enum.reduce_while(workers, :ok, fn worker_uri, :ok ->
      target = Ezagent.URI.new!("#{URI.to_string(worker_uri)}?action=sandbox.write_path")

      # codex E2E fix v2 Bug A (2026-05-29) — the Agent Kind was just
      # spawned by `template_class.instantiate/3`. `Kind.Server.init/1`
      # registers `:not_ready` synchronously and returns
      # `{:continue, :announce_ready}`; the `:ready` flip happens
      # asynchronously in `handle_continue` after the post-init Behavior
      # chain runs. The orchestrator-spawn path
      # (`Session.ensure_orchestrator` → `spawn_from_template_content` →
      # `record_sandbox_state`) hits this dispatch microseconds after
      # `start_link` returns — typically before the GenServer's
      # `handle_continue(:announce_ready, ...)` message has been
      # processed. A `:call` dispatch in that window fails fast with
      # `{:error, :not_ready}` (hard invariant #3, so the synchronous
      # caller doesn't block on `deadline_ms`), and the Sandbox slice's
      # `respawn_template_data` never gets written — which means
      # `Sandbox.post_init/2` cannot re-spawn the PTY subprocess on the
      # next phx restart. Allen e2e symptom 2026-05-28 was
      # `{:sandbox_write_path_failed, %URI{cc_orchestrator-main},
      # :not_ready}`.
      #
      # `ReadyGate.await/2` is the structural fix — a bounded poll
      # (5s test-tolerance bound; production typically resolves in
      # 1-2ms once the post-init chain completes). The wait is only
      # "best-effort accelerate the success path"; if the bound is
      # exhausted (impossible in practice except under DBConnection
      # contention) the dispatch is still attempted and the original
      # `:not_ready` shape is preserved for callers' error handling.
      _ = Ezagent.ReadyGate.await(worker_uri, 5_000)

      case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target,
             mode: :call,
             args: %{
               config_dir_path: config_dir,
               template_class: template_class,
               respawn_template_data: respawn_data
             },
             # SPEC caps-cleanup-v1 §4.4 — Agent sandbox-state record
             # is an agent-internal action; runs under
             # `system://agent-internal` (closed Catalog).
             ctx: %{
               caller: Ezagent.SystemPrincipal.uri("agent-internal"),
               caps:
                 "agent-internal"
                 |> Ezagent.SystemPrincipal.uri()
                 |> Ezagent.SystemPrincipal.caps(),
               reply: {:caller_inbox, self()}
             }
           }) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:sandbox_write_path_failed, worker_uri, reason}}}
      end
    end)
  end

  # PR3 2026-05-24 — additional rollback (beyond `undo_fresh_workers/1`)
  # for the case where `record_sandbox_state/3` itself fails: the per-
  # agent config_dir was created by the plugin's `instantiate/3` but
  # the slice was never populated, so `Sandbox.invoke(:destroy, ...)`
  # would never know to clean it up. Call the plugin's
  # `destroy_config_dir/2` directly with the path we know
  # PR-3 (domain.agent D2/DD-1) — the per-agent config_dir path authority is core
  # (`Ezagent.Sandbox.ConfigDir`), NOT the plugin. The domain derives the dir from
  # the agent URI + the class's namespace (no dependency on a plugin path builder)
  # and asks the plugin only to MATERIALIZE-cleanup it via `destroy_config_dir/2`.
  defp cleanup_partial_config_dirs(workers, template_class) do
    cond do
      not is_atom(template_class) ->
        :ok

      not function_exported?(template_class, :destroy_config_dir, 2) ->
        :ok

      true ->
        namespace = Ezagent.Kind.Template.namespace_of(template_class)

        Enum.each(workers, fn worker_uri ->
          dir = Ezagent.Sandbox.ConfigDir.path(worker_uri, namespace)
          _ = template_class.destroy_config_dir(worker_uri, dir)
        end)
    end
  end

  # codex round-10 HIGH-2 — establish lineage + workspace binding for
  # each freshly-created worker as a CHECKED step. `record_lineage/2`
  # always returns `:ok`; `bind_workspace/2` may not — a failure here is
  # returned as `{:error, {:post_spawn_obligation_failed, _}}` (NOT
  # raised) so the caller can self-clean. `Enum.reduce_while/3` stops at
  # the first failure.
  defp establish_post_spawn_obligations(workers, spawned_by_uri, workspace_uri) do
    Enum.reduce_while(workers, :ok, fn worker_uri, :ok ->
      with :ok <- record_lineage(worker_uri, spawned_by_uri),
           :ok <- bind_workspace(worker_uri, workspace_uri) do
        {:cont, :ok}
      else
        other ->
          {:halt, {:error, {:post_spawn_obligation_failed, worker_uri, other}}}
      end
    end)
  rescue
    error ->
      {:error, {:post_spawn_obligation_failed, :exception, error}}
  end

  # codex round-10 HIGH-2 — undo everything `spawn_from_template_content/4`
  # established for the workers IT freshly created, when a post-spawn
  # step fails: terminate the Kind process, forget the lineage row,
  # unbind the workspace. Best-effort + idempotent — a worker for which
  # the obligation never ran (binding/lineage absent) just no-ops.
  # `Ezagent.Kind.terminate/1` is the tier-clean Kind-process teardown;
  # `AgentLineage`/`WorkspaceRegistry` are ESR-domain registries this
  # ESR-layer helper legitimately owns (it is the layer that recorded
  # them — unlike the plugin Template Class, which must not touch them).
  defp undo_fresh_workers(workers) do
    Enum.each(workers, fn worker_uri ->
      _ = Ezagent.Kind.terminate(worker_uri)
      safe(fn -> Ezagent.WorkspaceRegistry.unbind(worker_uri) end)

      if Code.ensure_loaded?(Ezagent.AgentLineage) and
           function_exported?(Ezagent.AgentLineage, :forget, 1) do
        safe(fn -> Ezagent.AgentLineage.forget(worker_uri) end)
      end
    end)

    :ok
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp bind_workspace(worker_uri, workspace_uri) do
    case Ezagent.WorkspaceRegistry.bind(worker_uri, workspace_uri) do
      :ok -> :ok
      other -> other
    end
  end

  defp record_lineage(agent_uri, granted_by) do
    if Code.ensure_loaded?(Ezagent.AgentLineage) and
         function_exported?(Ezagent.AgentLineage, :record, 2) do
      Ezagent.AgentLineage.record(agent_uri, granted_by)
    else
      # AgentLineage registry not loaded — log + continue. PR 42's
      # {:spawned_by, _} cap shape returns false in this case, so
      # absence of lineage data degrades gracefully (no false grants).
      require Logger

      Logger.debug(
        "Ezagent.Entity.Agent.spawn: AgentLineage registry not loaded; " <>
          "{:spawned_by, _} cap shapes will deny for #{Ezagent.URI.stable_key(agent_uri)}"
      )

      :ok
    end
  end
end
