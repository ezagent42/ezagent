defmodule Ezagent.Entity.Agent do
  @moduledoc """
  Agent Kind — represents an external participant (e.g. a Claude CLI
  session via the CC bridge) inside Ezagent's chat router.

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

  @doc """
  List the agent URIs in `ws` — workspace-scoped, type-filtered, covering LIVE
  **and** DORMANT agents (membership-cap unification R1.4, spec test 26).

  Sourced from the persisted `kind_snapshots` rows (modeled EXACTLY on
  `Ezagent.AgentRecipeResolver`'s snapshot scan — `agent_role_resolver.ex:35-64`),
  NOT the volatile ETS/`KindRegistry` fast path, so a dormant agent member (a
  snapshot row with no live Kind) still enumerates after a BEAM restart — exactly
  why the reconcile candidate scan (§4.4) and the migration need it.

  Used in three places: (a) `reconcile_after_load/2` candidate enumeration (union
  with `Users.list_in_workspace/1`); (b) the member-cap migration's agent members;
  (c) the at-join agent member-cap path. `KindSnapshot.list_in_workspace/1` bounds
  the tenant (K4 — no cross-workspace leak) and the `kind_type == "agent"` filter
  excludes users/sessions/templates. A row whose `uri` cannot parse is dropped.
  """
  @spec list_in_workspace(URI.t()) :: [URI.t()]
  def list_in_workspace(%URI{} = ws) do
    ws
    |> Ezagent.Ecto.KindSnapshot.list_in_workspace()
    |> Enum.filter(fn row -> row.kind_type == Atom.to_string(type_name()) end)
    |> Enum.map(fn row -> row.uri end)
    |> Enum.map(&safe_uri/1)
    |> Enum.reject(&is_nil/1)
  rescue
    error in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
      require Logger

      Logger.warning(
        "Ezagent.Entity.Agent.list_in_workspace/1: snapshot scan failed for " <>
          "#{URI.to_string(ws)}: #{inspect(error.__struct__)}"
      )

      []
  end

  defp safe_uri(uri) when is_binary(uri) do
    case Ezagent.URI.parse(uri) do
      {:ok, %URI{} = u} -> u
      _ -> nil
    end
  end

  defp safe_uri(%URI{} = uri), do: uri
  defp safe_uri(_), do: nil

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
  # PR-6+7 (im/session/agent decomposition §3.5 / §OQ-1) introduced a declared
  # Agent behavior SUPERSET for folded flavors. A2/A3 makes that set
  # plugin-derived: every registered flavor targeting this Kind may declare an
  # `instance_behaviors/0` thunk. The Kind exposes the union for Capability/
  # BehaviorRegistry declaration, while each concrete instance still activates
  # only its persisted `:behaviors` set (or the base nil-capture set).
  @impl Ezagent.Kind
  def behaviors do
    (base_behaviors() ++ registry_instance_behaviors())
    |> Enum.uniq()
  end

  @doc """
  The BASE (non-flavor) Agent behavior set — the pre-PR-6 declared list.

  This is the `nil_capture_behavior_set/0` default below, so a legacy
  agent (cc / codex / echo) with a `nil`/absent `:kind_base` resolves to
  exactly this set (byte-identical to pre-PR-6) even though `behaviors/0`
  now declares the wider curl superset.
  """
  @spec base_behaviors() :: [module()]
  def base_behaviors,
    do: [
      Ezagent.ActionSet.Identity,
      Ezagent.ActionSet.Sandbox,
      Ezagent.ActionSet.ApiKeys,
      Ezagent.ActionSet.CredentialGrant,
      # Agent-owned config evolution (spec 2026-06-11 rev 4) — the agent
      # mutates its OWN config under its own authority, dissolving the #607
      # confused-deputy. Registered (CapabilityRegistry) in
      # EzagentDomainIdentity.Application, like the other identity-domain
      # behaviors that live on the Agent Kind.
      Ezagent.ActionSet.ConfigEvolve,
      # Minimal CR (change-request) config governance (SPEC
      # docs/together/2026-06-26 rev 3) — a Lifecycle sibling to ConfigEvolve
      # on the Agent Kind. stage → preview → publish → rollback over the SAME
      # ConfigStore + sandbox-materialization primitives. Registered in
      # EzagentDomainIdentity.Application alongside ConfigEvolve.
      Ezagent.ActionSet.ConfigGovernance
    ]

  defp registry_instance_behaviors do
    Ezagent.AgentFlavorRegistry.list_all()
    |> Enum.flat_map(fn
      {_flavor, %{kind: __MODULE__, instance_behaviors: fun}} when is_function(fun, 0) ->
        fun.()

      _ ->
        []
    end)
  end

  @doc """
  The curl-flavor per-instance behavior subset (the explicit `:behaviors`
  set threaded at a NEW curl agent spawn, PR-6). The BASE Agent behaviors
  PLUS `Ezagent.ActionSet.CurlAgent` (which owns the `:curl_agent` slice +
  `reset_conversation` / `configure` / `sync_result` actions). `:api_keys`
  is already in the base set, so curl's credential need is satisfied with no
  duplication.
  """
  @spec curl_behaviors() :: [module()]
  def curl_behaviors, do: base_behaviors() ++ [Ezagent.ActionSet.CurlAgent]

  @doc """
  Behavior set for the `cc-headless` flavor.

  The base Agent behaviors handle identity, sandbox, credentials, and generic
  receive. `Behavior.CcHeadlessAgent` owns the SDK sync-result persistence and
  session reply step.
  """
  @spec cc_headless_behaviors() :: [module()]
  def cc_headless_behaviors, do: base_behaviors() ++ [Ezagent.ActionSet.CcHeadlessAgent]

  @doc """
  Behavior set for a `nil`/absent `:kind_base` instance (PR-6). Returns the
  BASE (non-flavor) subset so legacy agents never gain the curl-only
  `Behavior.CurlAgent` that `behaviors/0` now declares for the curl flavor.
  See `Ezagent.Kind.nil_capture_behavior_set/1` + `Ezagent.Kind.BehaviorSet`.
  """
  @spec nil_capture_behavior_set() :: [module()]
  def nil_capture_behavior_set, do: base_behaviors()

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
    Agent.spawn/4 is the Ezagent-side Kind registration, not the
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
             :ok <- Ezagent.Entity.Agent.SpawnObligations.record_lineage(agent_uri, granted_by) do
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
             :ok <- Ezagent.Entity.Agent.SpawnObligations.record_lineage(agent_uri, granted_by) do
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
  guarantee is **per-session `role_name` uniqueness** (enforced session-side
  at `chat.join` via `role_name_conflict/3`, team-routing-unification §3.1)
  — two members in one session cannot share
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
  Synchronously ask a curl-flavor agent for an LLM completion and return the
  text. Authorized by cap (lead #1239 finalize ①): the `caller_uri` must
  either be the agent's **owner** (`AgentLineage.spawned_by` — always
  passes), or hold a `cap(:agent, ActionSet.Agent.Complete, :complete,
  agent_uri, workspace_uri)` granted by the agent's owner (#161 owner-authority
  chain — no unowned caps).

  Reuses `Ezagent.AgentBridge.deliver_with_flavor/3` synchronously — the curl
  adapter reads the agent's `:api_keys` + `:curl_agent` snapshot slices and
  does the HTTP round-trip. The CALLER never sees the API key.
  """
  @spec complete(URI.t(), URI.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def complete(%URI{} = caller_uri, %URI{} = agent_uri, prompt)
      when is_binary(prompt) do
    ws = Ezagent.Capability.workspace_of(agent_uri)

    with {:ok, owner} <- Ezagent.AgentLineage.lookup(agent_uri),
         :ok <- authorize_complete(caller_uri, owner, agent_uri, ws) do
      Ezagent.AgentBridge.complete(agent_uri, prompt)
    else
      :error -> {:error, :agent_owner_unresolvable}
      {:error, _} = err -> err
    end
  end

  defp authorize_complete(caller, owner, _agent_uri, _ws) when caller == owner, do: :ok

  defp authorize_complete(caller, _owner, agent_uri, ws) do
    needed =
      Ezagent.Capability.cap(
        :agent,
        Ezagent.ActionSet.Agent.Complete,
        :complete,
        agent_uri,
        ws
      )

    if Ezagent.Kind.holds_cap?(__MODULE__, caller, needed) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defdelegate spawn_from_template_content(content, instance_uri, spawned_by, workspace_uri),
    to: Ezagent.Entity.Agent.TemplateSpawn

  defdelegate content_to_template_data(content, instance_uri),
    to: Ezagent.Entity.Agent.TemplateSpawn

  defdelegate spawn_from_template_content(content, instance_uri, spawned_by, workspace_uri, opts),
    to: Ezagent.Entity.Agent.TemplateSpawn

  @doc """
  Spawn an agent from an authored `Ezagent.AgentManifest`, trying the
  executor flavor list in order through the existing template spawn path.
  """
  defdelegate spawn_from_manifest(manifest, slots, instance_uri, spawned_by, workspace_uri, opts),
    to: Ezagent.Entity.Agent.TemplateSpawn

  defdelegate sanitize_respawn_template_data(respawn_data, template_content),
    to: Ezagent.Entity.Agent.TemplateSpawn
end
