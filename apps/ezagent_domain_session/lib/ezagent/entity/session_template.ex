defmodule Ezagent.Entity.SessionTemplate do
  @moduledoc """
  SessionTemplate Kind — what a team looks like (Phase 7 PR 38).

  Per SPEC D7-2 + D7-7 + D7-10. A SessionTemplate is the
  **production unit of multi-agent orchestration** — a named,
  versioned, forkable configuration describing:

  - which agent slots compose the team
  - which AgentTemplate (PR 37) each slot is instantiated from
  - what routing rules wire the team together (mention routing,
    workspace scope)
  - which orchestrator agent is bundled with the session
  - what workspace newly-instantiated sessions land in
  - lineage back to a parent template (for fork tracking)

  ## URI shape (D7-10 git-style versioning, SPEC v3 §3.6 PR-7)

  `template://session/<workspace>/<name>@<version_hash>` where
  `version_hash` is **SHA-256 over the slice content** (canonical
  encoding, excluding timestamps + created_by). Two rows with
  identical config produce identical hashes — content-addressable.
  The hash is **immutable per row**. `orchestrator.update_template()`
  produces a new row with a new hash.

  PR-7 added the workspace segment so SessionTemplate URIs follow
  the same unified 3-segment shape as every other per-tenant URI.

  Tags (`v1.0`, `stable`, etc.) live in a separate `template_tags`
  registry mapping `(name, tag) → version_hash`. Tags are
  **mutable** — they can be re-pointed at any existing hash for
  the same name. Like git: branches/tags move, commits don't.

  ## Slice schema (per SPEC v3 §SessionTemplate + team-routing-unification §3.7)

      %{
        # metadata
        name:                       String.t(),
        description:                String.t(),

        # team composition (team-routing-unification §3.7, PR-7)
        # `members` — the members captured because `in_session_template: true`
        #   (§3.1): each `%{uri, role_name, in_session_template, source_template_uri}`.
        #   A spawned agent member carries `source_template_uri` (recreate-from);
        #   a plain invited member carries its `uri`. (`agent_slots` REMOVED —
        #   PR-8 removes the slot tools.)
        members:                    [map()],
        # `prompt_templates` — the named template map (§3.4): name => template str.
        prompt_templates:           %{optional(String.t()) => String.t()},
        # `installs` — product/runtime install refs consumed by
        # `Ezagent.Session.InstallCatalog` during materialization.
        # P3 built-ins: "chat" and "socialware"; absent preserves "chat".
        installs:                   [String.t()],
        # `legends` — the §3.6 legend defs: name => %{member_set, bound_rule_set, fold}.
        legends:                    %{optional(String.t()) => map()},
        # `nil` for a PLAIN (orchestrator-less) template — the create flow
        # in `SessionCreator` takes its no-orchestrator arm. Task #58 made
        # the default template's value a deployment seam, so a cc-less build
        # seeds the default with `nil` here.
        orchestrator_template_uri:  URI.t() | nil,
        # rule-set routing rules (§3.3): each
        #   `%{matcher, receivers, rule_set, position, prompt_template_ref}`.
        routing_rules:              [map()],
        default_workspace_uri:      URI.t(),

        # lineage (D7-7 fork model)
        parent_template_uri:        URI.t() | nil,

        # versioning (D7-10)
        version_hash:               String.t(),
        version_tag:                String.t() | nil,

        # provenance
        created_at:                 DateTime.t(),
        created_by:                 URI.t()
      }

  ## Persistence

  `{:snapshot, :on_change}` — SessionTemplates are durable
  configuration; orchestrators need them surviving phx restart so
  `list_templates` returns the catalog regardless of when phx
  started.

  ## Fork vs update vs save_template_as (orchestrator-facing)

  Three operations write SessionTemplate rows; clear separation
  matters because they're frequently confused:

  - **`update_template()`** (orchestrator tool, PR 46): produces a
    NEW VERSION of the **current parent template**. New `version_hash`
    row inserted; older sessions on prior hashes are unaffected.
    Requires `template:write` cap on the parent's name.
  - **`save_template_as(new_name)`** (orchestrator tool, PR 46):
    creates the FIRST VERSION of a NEW template with
    `parent_template_uri = current_parent_hash_uri`. Requires
    template-creation cap (default-granted to most users).
  - **`fork/3`** (`fork(parent_uri, new_name, opts)` — registry
    operation, NOT an orchestrator tool, see Decision #141): cold-fork
    from any template hash URI; the orchestrator inside a running
    session uses `save_template_as` for its in-session equivalent.
    `fork` is a SessionTemplate registry verb — a **session-creation
    entry point** (Phase 7 completion SPEC §2 PR-6). It copies the
    parent's CONFIG into a new SessionTemplate Kind with
    `parent_template_uri` set to the parent, persists via
    `persist_version/2`, and grants the owner a `Behavior.Template`
    cap (§1.7 (e)). The parent template row is **immutable** — `fork`
    never `:write`s the parent.
  - **`create/3`** (`create(new_name, config, opts)` — Phase 7
    completion SPEC §2 PR-6): a **session-creation entry point** that
    makes a NEW ROOT template (`parent_template_uri: nil`) from a
    caller-supplied team `config`; persists via `persist_version/2`,
    grants the owner cap.

  Both `fork/3` and `create/3` require a `Behavior.Template`
  `:session_template` cap as a preflight (§1.4) — a caller without it
  → `{:error, :unauthorized}`. Neither instantiates a session;
  instantiation is `EzagentDomainInstanceMessage.SessionCreator.create_session/3`.

  Fork unit = configuration only. Message history does NOT fork
  (D7-7) — a forked/instantiated session starts with EMPTY chat.

  ## Instantiation (EzagentDomainInstanceMessage.SessionCreator.create_session/3 — 2026-05-31)

  The dead `Session.spawn_from_template/2` Generator was DELETED in the
  2026-05-31 orchestrator-startup-atomicity pass (SPEC §1/§7 — it was
  production-dead, the live path never dispatched to it). A
  SessionTemplate is now instantiated into a running Session by the
  atomic `EzagentDomainInstanceMessage.SessionCreator.create_session/3` writer: it resolves the
  `template_name` → this SessionTemplate, reads its
  `orchestrator_template_uri`, and materializes the session's
  `template_working_copy` (OTU + `session_template_uri`) directly,
  then atomically ensures the orchestrator + grants caps + registers
  the MCP context + joins `[owner, orchestrator]` (SPEC §4).

  team-routing-unification §3.7 (PR-7) — `create_session/3` now also
  MATERIALIZES the template's team after that join: it recreates +
  joins each `in_session_template: true` member (spawned members via
  the unified `Agent.spawn/4` path from their `source_template_uri`;
  plain members via their `uri`), installs the template's
  `prompt_templates` + `legends`, and installs the rule-set routing
  rules — so an instantiated/forked template actually PRODUCES the
  working team (the load-bearing contract codex flagged). The
  orchestrator may still dispatch additional workers dynamically at
  runtime; PR-8 removes the residual `template_working_copy.agent_slots`
  slot tools.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :session_template

  # Phase 7 completion PR-1 (SPEC §1.0): SessionTemplate carries TWO
  # slices — `:identity` (the cap policy) and `:template` (the
  # versioned, content-addressed template CONTENT, served via
  # `Ezagent.ActionSet.Template`). SessionTemplate `:write` is
  # write-once + hash-checked (codex rev-5 CRITICAL).
  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.ActionSet.Identity, Ezagent.ActionSet.Template]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  # V1 prevention (Allen 2026-05-21): SessionTemplate Kinds live under
  # the chat domain's SessionTemplateSupervisor. `Ezagent.Kind.spawn/2`
  # reads this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainInstanceMessage.SessionTemplateSupervisor

  @doc """
  Compute the deterministic version hash for a slice content map.

  Excludes `created_at` + `created_by` + `version_hash` + `version_tag`
  + **`name`** from the hash input (Phase 7 completion SPEC §1.3). The
  hash is `term_to_binary` over ALL OTHER content fields — so the
  team-routing-unification §3.7 (PR-7) additions (`members`,
  `prompt_templates`, `legends`) and `routing_rules` /
  `orchestrator_template_uri` / `default_workspace_uri` / `description`
  are ALL content-addressed: a change to any of them yields a new
  version hash. (`agent_slots` is no longer a content field — PR-8
  removes the slot tools.) Dropping `name` means two
  sessions with an identical team config produce the SAME content hash
  regardless of the template name they are saved under — the
  build-working-copy GATE (PR-2). The `name` is carried by the URI's
  path segment, not the hash: a hash is the identity of the CONFIG, and
  a rename is not a new config version.

  Uses `:erlang.term_to_binary(slice, [:deterministic])` for
  cross-BEAM-run consistency (D7-10).

  Returns a 64-char lowercase hex string (SHA-256 hex digest).
  """
  @spec compute_version_hash(map()) :: String.t()
  def compute_version_hash(slice_content) when is_map(slice_content) do
    canonical =
      slice_content
      # codex MINOR — `agent_slots` is no longer a content field (PR-8
      # removed the slot tools). Strip BOTH the atom and the string key so
      # a vestigial slot list (e.g. a string-keyed JSON tool boundary) can
      # never ride into the version hash and silently fork the identity.
      |> Map.drop([
        :created_at,
        :created_by,
        :version_hash,
        :version_tag,
        :name,
        :agent_slots,
        "agent_slots"
      ])
      |> :erlang.term_to_binary([:deterministic])

    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  @doc """
  Build the URI for a SessionTemplate given name + version hash.

  SPEC v3 §3.6 (Phase 9 PR-7) — workspace is the second path segment.
  Per SPEC #324, there is no silent global default — `opts[:workspace]`
  is REQUIRED (string, no scheme prefix). Callers (`AgentNewLive`,
  `Workspace.add_template`, mix tasks, `create/3` below) all pass it
  explicitly; missing key raises `ArgumentError`.
  """
  @spec build_uri(String.t(), String.t(), keyword()) :: URI.t()
  def build_uri(name, version_hash, opts \\ [])
      when is_binary(name) and is_binary(version_hash) do
    workspace =
      Keyword.get(opts, :workspace) ||
        raise(
          ArgumentError,
          "Ezagent.Entity.SessionTemplate.build_uri/3 requires opts[:workspace] " <>
            "(SPEC #324 — no silent \"default\" fallback). Pass the workspace name " <>
            "(e.g. \"system\" for admin templates, \"team-alpha\" for tenant)."
        )

    Ezagent.URI.template(workspace, :session, "#{name}@#{version_hash}")
  end

  @doc """
  Persist a SessionTemplate version (Phase 7 completion SPEC §1.7 (a)).

  This is the persistence helper that stands on the Kind/`kind_snapshots`
  model — a SessionTemplate version IS a Kind instance, there is no
  separate "SessionTemplate row" table. Given the template content map
  + the workspace, `persist_version/2`:

  1. computes the content hash via `compute_version_hash/1` — this
     content-addresses the version (identical content ⇒ identical
     hash ⇒ identical URI);
  2. builds the version URI `template://session/<ws>/<name>@<hash>`
     via `build_uri/3`;
  3. **spawns the SessionTemplate Kind** at that URI through
     `Ezagent.SpawnRegistry.spawn/1` (the `template` scheme spawn fn
     routes to `Ezagent.Kind.spawn(SessionTemplate, …)`);
  4. dispatches `Ezagent.ActionSet.Template` `:write` (`?action=template.write`)
     to populate the Kind's `:template` content slice. Because
     SessionTemplate is `{:snapshot, :on_change}`, that slice mutation
     writes a `kind_snapshots` row keyed by the hash URI — the
     persistence is the snapshot.

  The `:write` action (PR-1) is the integrity guard: it is write-once
  + hash-checked. It recomputes the hash over `content` and requires it
  to equal the URI's `@<hash>` segment — `persist_version/2` builds the
  URI from the same hash, so a correctly-formed call always passes; a
  caller that hands content whose hash disagrees with a pre-built URI
  is rejected with `{:error, :hash_mismatch}`.

  ## Idempotent on a duplicate hash

  Persisting the SAME content twice resolves to the SAME hash ⇒ the
  SAME URI. The second call finds the Kind already alive
  (`SpawnRegistry.spawn/1` → `{:error, {:already_started, pid}}`) and
  re-dispatches `:write` with identical content — the `:write` action's
  identical-retry no-op (`check_immutable/2` `same, same`) returns
  `{:ok, …}`. Both calls return `{:ok, uri}`; exactly one
  `kind_snapshots` row exists; no error is raised. This is the
  content-addressing idempotency convention of SPEC §1.7 (a).

  ## Caller context — HIGH-9 hardening

  The `:write` dispatch's `ctx` is **threaded from the caller**, never a
  blanket `admin_caps()` fallback (codex HIGH-9). The pre-hardening
  `persist_version/2` always dispatched `template.write` with
  `User.admin_uri/0` + `User.admin_caps/0` — so the decisive
  template-persistence write of the orchestrator's `update_template` /
  `save_template_as` tools ran under ambient admin authority,
  contradicting "no `admin_caps` in the tool path".

  `persist_version/3` takes an `opts` keyword carrying `:caller` +
  `:caps`. The orchestrator tools pass the orchestrator's own context;
  `fork/3` / `create/3` pass the caller's context. The `:write` action
  is then CapBAC-checked against that REAL authority. Only the
  explicitly-named **system-internal** entry point
  `persist_version_as_system/2` uses the bootstrap principal — and that
  is NEVER on the MCP tool path.

  `persist_version/2` is retained as a thin shim over
  `persist_version_as_system/2` for back-compat with test fixtures and
  callers that already hold no caller context. New tool-path code MUST
  use `persist_version/3` with a threaded `ctx`.

  ## Returns

  - `{:ok, uri}` — the version was persisted (or already existed with
    identical content); `uri` is the `template://session/...@<hash>`
    URI of the version.
  - `{:error, reason}` — the spawn failed, or the `:write` dispatch
    failed (e.g. `:hash_mismatch` for caller-supplied content that
    doesn't agree with its hash, or `:unauthorized` if the threaded
    caps do not authorize the `template.write`).
  """
  @spec persist_version(map(), URI.t() | String.t()) ::
          {:ok, URI.t()} | {:error, term()}
  def persist_version(content, workspace) when is_map(content) do
    persist_version_as_system(content, workspace)
  end

  @doc """
  Persist a SessionTemplate version with a CALLER-THREADED dispatch
  context (HIGH-9 hardening) — the variant the MCP tool path uses.

  Identical to `persist_version/2` except the `template.write` dispatch
  `ctx` is built from `opts[:caller]` + `opts[:caps]` instead of the
  bootstrap admin principal. `opts` MUST carry both `:caller` (`%URI{}`)
  and `:caps` (a `MapSet`/list of `Capability.t()`). The `:write`
  action's CapBAC then enforces the caller's REAL authority — a caller
  whose threaded caps do not authorize `template.write` on the version
  URI gets `{:error, :unauthorized}`, with NO admin fallback.
  """
  @spec persist_version(map(), URI.t() | String.t(), keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def persist_version(content, workspace, opts) when is_map(content) and is_list(opts) do
    with {:ok, ctx} <- build_caller_ctx(opts) do
      do_persist_version(content, workspace, ctx)
    end
  end

  @doc """
  Persist a SessionTemplate version under the SYSTEM-INTERNAL bootstrap
  principal (HIGH-9 — explicitly named, NOT on the MCP tool path).

  Used by boot-seed / fixture paths that have no caller context. The
  orchestrator's `update_template` / `save_template_as` tools MUST NOT
  call this — they use `persist_version/3` with a threaded `ctx`.
  """
  @spec persist_version_as_system(map(), URI.t() | String.t()) ::
          {:ok, URI.t()} | {:error, term()}
  def persist_version_as_system(content, workspace) when is_map(content) do
    do_persist_version(content, workspace, system_ctx())
  end

  defp do_persist_version(content, workspace, ctx) when is_map(content) do
    # codex MINOR — strip `agent_slots` (atom AND string key) before BOTH
    # the hash and the persisted `:write`, so a vestigial slot list never
    # lands in durable content nor shifts the content hash. This is the
    # single persistence chokepoint (`fork`/`create`/system-seed all route
    # here), so the strip covers every write path.
    content = Map.drop(content, [:agent_slots, "agent_slots"])
    name = Map.get(content, :name) || Map.get(content, "name")
    workspace_segment = workspace_segment(workspace)

    cond do
      not (is_binary(name) and name != "") ->
        {:error, :missing_template_name}

      is_nil(workspace_segment) ->
        {:error, :invalid_workspace}

      true ->
        hash = compute_version_hash(content)
        uri = build_uri(name, hash, workspace: workspace_segment)

        with {:ok, _result} <- ensure_alive_and_write(uri, content, ctx) do
          {:ok, uri}
        end
    end
  end

  # #108 — spawn-readiness / dead-target race. `ensure_kind_alive/1` returns
  # `{:ok, pid}` (a freshly-spawned Kind, or an already-alive boot-seeded one),
  # but the subsequent `template.write` dispatch can still land in a teardown
  # window and come back `:no_such_actor`:
  #
  #   * the boot-seeded SessionTemplate Kind crashed MID-dispatch (its own DB
  #     write hit a sandbox connection whose owner churned) → `:dead_target` →
  #     `:no_such_actor`; or
  #   * the Registry has not yet reaped a just-terminated pid, so the dispatch
  #     observes a stale `:ready` gate over a dead pid.
  #
  # Both are transient and self-heal: the Registry reaps the dead pid, then the
  # next `ensure_kind_alive` either lazy-respawns from the now-persisted
  # snapshot or starts a fresh Kind whose init re-registers + marks ready, and
  # the dispatch path's own `ReadyGate.await` covers the not-ready tail. So
  # retry the ensure+dispatch pair a bounded number of times on `:no_such_actor`
  # ONLY (every other error propagates immediately). `dispatch_write` is
  # `:no_such_actor`-idempotent: that error is a PRE-delivery failure (the write
  # never ran), so a retry cannot double-apply. After the budget is exhausted we
  # return the same `{:error, :no_such_actor}` the caller saw before — no
  # masking, just resilience. This is the chokepoint for seed / fork / create /
  # save_template_as, so all share the hardening.
  @write_retries 8
  @write_retry_delay_ms 25

  defp ensure_alive_and_write(uri, content, ctx, attempts_left \\ @write_retries) do
    with {:ok, _pid} <- ensure_kind_alive(uri),
         {:ok, result} <- dispatch_write(uri, content, ctx) do
      {:ok, result}
    else
      {:error, :no_such_actor} when attempts_left > 0 ->
        Process.sleep(@write_retry_delay_ms)
        ensure_alive_and_write(uri, content, ctx, attempts_left - 1)

      {:error, _} = err ->
        err
    end
  end

  # Build the `template.write` dispatch ctx from a caller-threaded opts
  # keyword. Both `:caller` and `:caps` are required (HIGH-9 — no
  # admin fallback on the caps-threaded path).
  defp build_caller_ctx(opts) do
    with {:ok, %URI{} = caller} <- fetch_opt(opts, :caller),
         {:ok, caps} <- fetch_opt(opts, :caps) do
      {:ok,
       %{
         caller: caller,
         caps: normalize_caps_set(caps),
         reply: {:caller_inbox, self()}
       }}
    end
  end

  defp normalize_caps_set(%MapSet{} = caps), do: caps
  defp normalize_caps_set(caps) when is_list(caps), do: MapSet.new(caps)
  defp normalize_caps_set(_), do: MapSet.new()

  defp system_ctx do
    # The concrete target does not exist until `do_persist_version/3` computes
    # its content-addressed URI. Keep only the canonical bootstrap identity
    # here; `dispatch_write/3` obtains the target-signed capability from that
    # target's sealed admin anchor after `ensure_kind_alive/1` has opened its
    # authority compartment.
    {:system_admin, Ezagent.Entity.User.admin_uri()}
  end

  defp template_admin_cap(action, %URI{} = target, %URI{} = admin_uri)
       when is_atom(action) do
    %Ezagent.Capability{
      Ezagent.Capability.cap(
        :session_template,
        Ezagent.ActionSet.Template,
        action,
        Ezagent.URI.instance(target),
        Ezagent.Capability.workspace_of(target)
      )
      | granted_by: admin_uri,
        granted_at: DateTime.utc_now()
    }
  end

  @doc """
  Fork a SessionTemplate — `fork(parent_uri, new_name, opts)` (Phase 7
  completion SPEC §2 PR-6).

  A **session-creation entry point**. `fork` is configuration-only
  (Decision #141 / D7-7): it copies the parent template's CONFIG into a
  new SessionTemplate, with `parent_template_uri` set to the exact
  `parent_uri@<hash>` it forked from — never message history, never a
  live session's chat. The parent template row is **immutable**: `fork`
  reads the parent's `:template` slice and persists a brand-new Kind at a
  brand-new content-hash URI; it never dispatches `:write` against the
  parent.

  ## What it does

  1. **Cap preflight** (§1.4) — the caller MUST hold a `Behavior.Template`
     cap for `:session_template` covering the parent's workspace. A
     caller without it → `{:error, :unauthorized}`. This is the
     template-create authority gate, symmetric with the owner cap
     `EzagentDomainInstanceMessage.SessionCreator.create_session/3` requires to instantiate.
  2. **Read the parent** — dispatch `Behavior.Template` `:read` on
     `parent_uri` to fetch its `:template` content. A parent with no
     populated slice / not resolvable → `{:error, _}`.
  3. **Build the fork content** — the parent's content, with `name`
     replaced by `new_name`, `parent_template_uri` set to `parent_uri`,
     `version_tag` cleared, and `created_by`/`created_at` refreshed.
  4. **Persist** — `persist_version/2` spawns a NEW SessionTemplate Kind
     at the fork's own content-hash URI and writes its `:template` slice.
  5. **Owner-cap grant** (§1.7 (e)) — grant the owner a `Behavior.Template`
     SessionTemplate cap (`{:within_workspace, ws}`) so they can later
     instantiate the fork via `EzagentDomainInstanceMessage.SessionCreator.create_session/3`.

  ## Options

  - `:caps` — the caller's cap set (`MapSet`/list of `Capability.t()`).
    Required — the preflight has nothing to check without it.
  - `:caller` — `%URI{}` of the principal performing the fork. Required.
  - `:owner` — `%URI{}` to receive the owner cap (§1.7 (e)). Defaults to
    `:caller`.
  - `:workspace` — the workspace the fork is created in. Defaults to the
    parent's workspace (the canonical choice — a fork lives alongside its
    parent).

  ## Returns

  - `{:ok, new_template_uri}` — the fork's `template://session/<ws>/<new_name>@<hash>` URI.
  - `{:error, :unauthorized}` — the caller lacks the SessionTemplate
    template cap.
  - `{:error, reason}` — read / persist failure.

  Does NOT instantiate a session — instantiation is
  `EzagentDomainInstanceMessage.SessionCreator.create_session/3`. `fork` returns the new template
  URI; the caller decides whether to instantiate it.
  """
  @spec fork(URI.t(), String.t(), keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def fork(%URI{} = parent_uri, new_name, opts \\ [])
      when is_binary(new_name) and new_name != "" do
    # PR1 2026-05-24 (Allen): SHIM — the real fork logic now lives in
    # `Ezagent.ActionSet.Template.invoke(:fork, ...)` so AgentTemplate
    # gets fork for free. This module function preserves the existing
    # public API (caller-threaded opts, return shape) and just dispatches.
    with {:ok, caps} <- fetch_opt(opts, :caps),
         {:ok, caller_uri} <- fetch_opt(opts, :caller),
         {:ok, _pid} <- ensure_kind_alive(parent_uri) do
      args = build_fork_args(new_name, opts, caller_uri)
      ctx = build_fork_ctx(caller_uri, caps)
      target = Ezagent.URI.new!("#{URI.to_string(parent_uri)}?action=template.fork")

      case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target,
             mode: :call,
             args: args,
             ctx: ctx
           }) do
        {:ok, %{template_uri: %URI{} = uri}} -> {:ok, uri}
        {:error, _} = err -> err
        other -> {:error, {:unexpected_fork_result, other}}
      end
    end
  end

  defp build_fork_args(new_name, opts, caller_uri) do
    owner = Keyword.get(opts, :owner, caller_uri)
    %{new_name: new_name, owner: owner}
  end

  defp build_fork_ctx(caller_uri, caps) do
    %{
      caller: caller_uri,
      caps: normalize_caps_set(caps),
      reply: {:caller_inbox, self()}
    }
  end

  @doc """
  Create a new ROOT SessionTemplate — `create(new_name, config, opts)`
  (Phase 7 completion SPEC §2 PR-6).

  A **session-creation entry point**. Unlike `fork/3`, `create` makes a
  template with NO parent (`parent_template_uri: nil`) — a blank root,
  the head of a fresh template family. The team `config` is supplied
  directly by the caller.

  ## What it does

  1. **Cap preflight** (§1.4) — the caller MUST hold a `Behavior.Template`
     cap for `:session_template` covering the target workspace. A caller
     without it → `{:error, :unauthorized}`.
  2. **Build the root content** — the supplied `config`, with `name`
     set to `new_name`, `parent_template_uri` forced to `nil` (a root
     never has a parent), `version_tag` cleared, and
     `created_by`/`created_at` stamped.
  3. **Persist** — `persist_version/2` spawns a new SessionTemplate Kind
     at its content-hash URI.
  4. **Owner-cap grant** (§1.7 (e)) — grant the owner a `Behavior.Template`
     SessionTemplate cap so they can later instantiate it.

  ## `config`

  A map of the SessionTemplate `:template` slice fields (any of
  `description`, `agent_slots`, `orchestrator_template_uri`,
  `routing_rules`, `default_workspace_uri`). `name` and
  `parent_template_uri` in `config` are overridden — `name` by
  `new_name`, `parent_template_uri` by `nil` (a root is parentless).

  ## Options

  - `:caps` — the caller's cap set. Required.
  - `:caller` — `%URI{}` of the principal. Required.
  - `:owner` — `%URI{}` to receive the owner cap. Defaults to `:caller`.
  - `:workspace` — the workspace the root is created in. REQUIRED
    (SPEC #324 — no silent `"default"` fallback). Pass the workspace
    name string (e.g. `"system"`, `"team-alpha"`).

  ## Returns

  - `{:ok, new_template_uri}` — the root's
    `template://session/<ws>/<new_name>@<hash>` URI.
  - `{:error, :unauthorized}` / `{:error, reason}`.

  Does NOT instantiate a session — see `fork/3`'s note.
  """
  @spec create(String.t(), map(), keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def create(new_name, config \\ %{}, opts \\ [])
      when is_binary(new_name) and new_name != "" and is_map(config) do
    workspace =
      Keyword.get(opts, :workspace) ||
        raise(
          ArgumentError,
          "Ezagent.Entity.SessionTemplate.create/3 requires opts[:workspace] " <>
            "(SPEC #324 — no silent \"default\" fallback)."
        )

    with {:ok, caps} <- fetch_opt(opts, :caps),
         {:ok, caller_uri} <- fetch_opt(opts, :caller),
         :ok <- require_session_template_cap(caps, workspace) do
      content =
        config
        |> normalize_config_keys()
        |> Map.put(:name, new_name)
        # A root template has NO parent — §2 PR-6 / D7-7.
        |> Map.put(:parent_template_uri, nil)
        |> Map.put(:version_tag, nil)
        |> Map.put(:created_by, caller_uri)
        |> Map.put(:created_at, DateTime.utc_now())

      persist_and_grant(
        content,
        workspace,
        Keyword.get(opts, :owner, caller_uri),
        caller: caller_uri,
        caps: caps
      )
    end
  end

  # --- fork / create internals -------------------------------------------

  # Persist the new SessionTemplate version, then grant the owner a
  # `Behavior.Template` cap (§1.7 (e)). The ordering is
  # template-Kind-first, cap-second — there is no shared SQL transaction
  # across two independent Kind snapshots, so the helper is honest about
  # it: a failed grant leaves the template existing (harmless) but the
  # function returns `{:error, _}` so the caller knows the owner cannot
  # yet instantiate it.
  #
  # HIGH-9 — the `template.write` runs under the CALLER's threaded
  # context (`persist_version/3`), not `admin_caps`. The caller already
  # passed `require_session_template_cap/2`, so its caps authorize the
  # write.
  defp persist_and_grant(content, workspace, owner_uri, caller_opts) do
    with {:ok, new_uri} <- persist_version(content, workspace, caller_opts),
         :ok <- grant_owner_template_cap(owner_uri, workspace) do
      {:ok, new_uri}
    end
  end

  # The cap preflight (SPEC §1.4) — the caller must hold a
  # `Behavior.Template` cap for `:session_template` covering `workspace`.
  # Builds the same `needed` shape CapBAC's `cap_for_action/3` derives
  # (a representative SessionTemplate URI in the workspace) and checks
  # `Capability.matches?/2` — so this boundary check stays structurally
  # aligned with dispatch CapBAC. `:any` admin caps,
  # `{:within_workspace, ws}` template caps, and broader template caps
  # all pass; a caller with no template authority is denied.
  defp require_session_template_cap(caps, workspace) do
    case workspace_uri(workspace) do
      {:ok, %URI{} = workspace_uri} ->
        workspace_name = Ezagent.URI.workspace_name!(workspace_uri)

        needed = %{
          kind: :session_template,
          behavior: Ezagent.ActionSet.Template,
          # SPEC 2026-05-27 capability-action-axis — `create/3`'s
          # preflight predates the action-axis. It checks "does the
          # caller hold ANY Template authority in the workspace?".
          # Action `:any` preserves the pre-SPEC predicate semantics;
          # a granular per-action gate is a future PR.
          action: :any,
          instance: Ezagent.URI.template(workspace_name, :session, "_preflight@_"),
          workspace_uri: workspace_uri
        }

        caps
        |> normalize_caps()
        |> Enum.any?(&Ezagent.Capability.matches?(&1, needed))
        |> case do
          true -> :ok
          false -> {:error, :unauthorized}
        end

      :error ->
        {:error, :invalid_workspace}
    end
  end

  # SPEC §1.7 (e) — after creating a new SessionTemplate, grant the
  # owner a `Behavior.Template` cap on `:session_template` for the
  # workspace so they may later instantiate it via the Generator (whose
  # owner-cap preflight, §1.4 / PR-4, checks exactly this cap).
  #
  # The grant dispatches `identity.grant_cap` on the owner's User Kind
  # under a system context — the WHO-may-create authority was already
  # enforced by `require_session_template_cap/2`. The ordering is
  # template-first, cap-second (§1.7 (e)).
  defp grant_owner_template_cap(%URI{} = owner_uri, workspace) do
    with {:ok, %URI{} = workspace_uri} <- workspace_uri(workspace) do
      cap = %Ezagent.Capability{
        kind: :session_template,
        behavior: Ezagent.ActionSet.Template,
        # SPEC 2026-05-27 capability-action-axis — owner needs full
        # lifecycle authority on templates they create (read, write/
        # update, instantiate, fork). The `:within_workspace` instance
        # scope is the structural narrowing; action axis stays `:any`.
        action: :any,
        instance: {:within_workspace, workspace_uri},
        workspace_uri: workspace_uri,
        granted_by: owner_uri,
        granted_at: DateTime.utc_now()
      }

      # Grant chokepoint (SPEC 2026-06-17 §4 PR-2, site #8). The cap is
      # `session_template/Template/:any/{:within_workspace}` — kind +
      # behavior concrete, instance scope-bounded `{:within_workspace}` —
      # so `IdentityAdmin.rule_cap_bounded?/1` is true → the `{:rule, …}`
      # branch authorizes it (Decision #154). The configurer of the
      # template-materialization rule is the template OWNER (also the
      # entity `granted_by`); `template-materialize` is no longer the
      # authorizer.
      Ezagent.Identity.Grant.grant_cap(
        owner_uri,
        cap,
        {:rule, :template_materialize, owner_uri}
      )
    end
  end

  # `read_template_content/1` was removed in PR1 2026-05-24 — the old
  # `fork/3` used it to fetch the parent slice via dispatch; the lifted
  # `Behavior.Template :fork` action runs IN-PROCESS with the parent
  # slice already in hand (matches the `:instantiate` rev-5 HIGH-2
  # deadlock-avoidance pattern).

  # Normalize a caller-supplied `config` map to atom keys for the known
  # SessionTemplate slice fields. String-keyed input (e.g. from a JSON
  # tool boundary) is coerced; unknown keys pass through untouched.
  # team-routing-unification §3.7 (PR-7): SessionTemplate content carries
  # `members` / `prompt_templates` / `legends`; `agent_slots` is NO LONGER a
  # content key (PR-8 removes the slot tools). Dropping it here means a
  # caller-supplied (string-keyed) `agent_slots` no longer atom-coerces into
  # the persisted content — it is not a template content field.
  # `installs` — the P3/P4 socialware composition field. Public anonymous web
  # access is no longer a SessionTemplate boolean; it is read from the installed
  # socialware definition's visibility policy.
  @config_atom_keys ~w(name description members prompt_templates legends
                       orchestrator_template_uri routing_rules
                       default_workspace_uri parent_template_uri
                       version_tag created_by created_at installs)a
  defp normalize_config_keys(config) do
    Map.new(config, fn
      {k, v} when is_atom(k) ->
        {k, v}

      {k, v} when is_binary(k) ->
        case Enum.find(@config_atom_keys, &(Atom.to_string(&1) == k)) do
          nil -> {k, v}
          atom_key -> {atom_key, v}
        end
    end)
  end

  # Coerce a caps opt (MapSet | list | nil) to a list for `Enum.any?`.
  defp normalize_caps(%MapSet{} = caps), do: MapSet.to_list(caps)
  defp normalize_caps(caps) when is_list(caps), do: caps
  defp normalize_caps(_), do: []

  # Resolve a workspace opt (URI | bare-name string) to a
  # `workspace://<name>` URI.
  defp workspace_uri(%URI{scheme: "workspace"} = uri), do: {:ok, uri}

  defp workspace_uri(other) do
    case workspace_segment(other) do
      name when is_binary(name) -> {:ok, Ezagent.URI.workspace(name)}
      nil -> :error
    end
  end

  defp fetch_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_opt, key}}
      v -> {:ok, v}
    end
  end

  # Spawn the SessionTemplate Kind at the hash URI. A duplicate-hash
  # persist finds the Kind already alive — `{:already_started, pid}` is
  # idempotency, treated as success (SPEC §1.7 (a)).
  defp ensure_kind_alive(uri) do
    case Ezagent.SpawnRegistry.spawn(uri) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end

  # Dispatch `Ezagent.ActionSet.Template` `:write` to populate the
  # `:template` slice — the `{:snapshot, :on_change}` mutation writes
  # the `kind_snapshots` row. An identical-content retry no-ops as
  # `{:ok, …}` (the write-once Kind is not corrupted).
  #
  # HIGH-9 — `ctx` is THREADED from the caller; the `:write` action is
  # CapBAC-checked against the caller's real authority. Only
  # `persist_version_as_system/2` passes a system (`admin`) ctx.
  defp dispatch_write(uri, content, {:system_admin, %URI{} = admin_uri}) do
    cap = template_admin_cap(:write, uri, admin_uri)

    with {:ok, signed_cap} <- Ezagent.Cap.issue({:admin, admin_uri}, admin_uri, cap) do
      dispatch_write(uri, content, %{
        caller: admin_uri,
        caps: MapSet.new([signed_cap]),
        reply: {:caller_inbox, self()}
      })
    end
  end

  defp dispatch_write(uri, content, ctx) when is_map(ctx) do
    target = Ezagent.URI.with_action(uri, :template, :write)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{content: content},
      ctx: ctx,
      origin: :trusted_internal
    })
  end

  # The workspace path segment (no scheme prefix) for `build_uri/3`.
  defp workspace_segment(%URI{scheme: "workspace"} = uri), do: Ezagent.URI.name!(uri)

  defp workspace_segment(name) when is_binary(name) and name != "" do
    case Ezagent.URI.parse(name) do
      {:ok, %URI{scheme: "workspace"} = uri} ->
        Ezagent.URI.name!(uri)

      {:ok, %URI{}} ->
        nil

      {:error, _} ->
        # Bare workspace name (no scheme) — accept it directly.
        if String.contains?(name, "/"), do: nil, else: name
    end
  end

  defp workspace_segment(_), do: nil
end
