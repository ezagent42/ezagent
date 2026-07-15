defmodule Ezagent.ActionSet.Template do
  @moduledoc """
  Template Behavior — the dispatchable template-CONTENT Behavior for the
  AgentTemplate + SessionTemplate Kinds (Phase 7 completion SPEC §1.0,
  codex rev-4 HIGH-1+2).

  ## Why this Behavior exists

  rev 3's persistence plan dispatched `identity.update_slice` to persist
  a template version and routed `add_agent_slot` to a bare
  `template.instantiate` callback. Both targeted **non-existent dispatch
  actions** — `Ezagent.ActionSet.Identity` exposes only
  `list_caps/has_cap?/grant_cap/revoke_cap` (and its `:identity` slice
  holds CAPS, not template content), and `Ezagent.Kind.Template` is a
  callback-module contract, not a `BehaviorRegistry`-registered action.

  `Ezagent.ActionSet.Template` is the fix: a real Behavior carrying the
  persistent template-CONTENT slice with dispatchable `:read` / `:write`
  / `:instantiate` actions, registered on BOTH Template Kinds.

  ## State slice — `:template`

  A NEW slice, separate from `:identity`. Both Template Kinds
  (AgentTemplate / SessionTemplate) carry `Ezagent.ActionSet.Identity`
  for the cap policy AND `Ezagent.ActionSet.Template` for the content:

  - `:identity` — the cap policy (`default_caps`, owner-grant caps)
  - `:template` — `%{content: map() | nil}` — the template CONTENT

  `init_slice/1` reads `args[:content]` (default `nil` — an unpopulated
  template Kind). The content map is the per-Kind schema:

  - **AgentTemplate `:template` content** — a UNIVERSAL base + FLAVOR-OWNED
    extras (SPEC 2026-06-01-flavor-generic-template-data, approach B).
    Universal: `name`, `description`, `flavor`, `project_cwd`,
    `default_caps`, `parent_template_uri` (nil for roots; set to the source
    URI on fork — PR1 2026-05-24), `created_by`, `created_at`. (PR-2:
    `working_directory` was split — the universal project/working dir is now
    `project_cwd`; the cc-flavor sandbox config-home input is `config_dir`.)
    Flavor-owned: each flavor's Template Class declares (via
    `template_data_extra/1`) which content fields its `instantiate/3` reads — cc:
    `config_dir`/`settings_path`/`mcp_config_path`/`api_key_helper`/
    `role`; curl: `provider`/`api_url`/`model`/`system_prompt`/`max_history`;
    codex: `model`/`approval_policy`/`sandbox`/… Core
    (`AgentTemplate.to_template_data/2`) is flavor-agnostic and validates the
    assembled data against the flavor's own `validate/1` (a template missing a
    required flavor field fails loud).
  - **SessionTemplate `:template` content** — `name`, `description`,
    `agent_slots`, `orchestrator_template_uri`, `routing_rules`,
    `default_workspace_uri`, `parent_template_uri`, `version_hash`,
    `version_tag`, `created_by`, `created_at`.

  ## Actions — `:read` / `:write` / `:instantiate` / `:fork`

  - **`:read`** (`:call`) — returns the `:template` slice content.
  - **`:write`** (`:call`, args `%{content: map}`) — persists the
    `:template` slice content. Because both Template Kinds are
    `{:snapshot, :on_change}`, a `:write` triggers a `kind_snapshots`
    row write — this is the persistence primitive. The snapshot layer
    upserts by URI, so `:write` is **kind-specific** (codex rev-5
    CRITICAL):
    - **SessionTemplate `:write` is write-once + hash-checked.**
      Recomputes `SessionTemplate.compute_version_hash/1` over `content`
      and requires it to equal the `@<hash>` segment of the Kind's own
      URI — a mismatch → `{:error, :hash_mismatch}`. A `:write` to a
      SessionTemplate whose `:template` slice is already non-empty →
      `{:error, :immutable_version}` UNLESS the new content is logically
      identical (an idempotent retry, which no-ops). A new version is a
      NEW Kind at a NEW `@<hash>` URI — `:write` NEVER edits an existing
      hash in place.
    - **AgentTemplate `:write` is a plain mutable replace** —
      AgentTemplate URIs are versionless (`template://agent/<ws>/<name>`,
      no `@<hash>`); an operator edits the config in place.
  - **`:instantiate`** (`:call`) — runs **inside the Template Kind
    process with the `:template` slice already in hand**. It does NOT
    re-dispatch `:read` to itself (a nested synchronous dispatch to the
    same instance is a self-`GenServer.call` deadlock — codex rev-5
    HIGH-2). For an **AgentTemplate** Kind: resolves the flavor Class
    via `Ezagent.AgentFlavorRegistry.lookup/1` and calls the in-process
    spawn helper `Ezagent.Entity.Agent.spawn_from_template_content/4`
    (§1.6a), which delegates the launch + records lineage + binds
    workspace from the in-hand content. For a **SessionTemplate** Kind:
    returns `{:error, :use_generator}` — SessionTemplate instantiation
    IS the Generator (`Session.spawn_from_template/2`, PR-4); the
    Behavior does not duplicate it.

    **Workspace authority (codex HIGH-1).** `template.instantiate` is
    CapBAC-checked against the AgentTemplate's own URI
    (`template://agent/<workspace>/<name>`) — only that workspace
    segment is authorized. The destination workspace the worker is
    spawned + bound into is therefore derived SOLELY from the
    AgentTemplate's own URI. An explicit `workspace_uri` arg is NOT a
    destination selector; if supplied it must equal the AgentTemplate's
    own workspace, otherwise the call is rejected
    `{:error, :cross_workspace_denied}`. Cross-workspace instantiation
    is not a V1 feature — there is no second-cap path.

  - **`:fork`** (`:call`, args `%{new_name: String.t(), owner: URI.t() | nil}`) —
    Allen 2026-05-24 PR1: lifted out of `SessionTemplate.fork/3` so EVERY
    Template Kind gets fork for free. Runs INSIDE the parent Template Kind
    process (slice already in hand → no `:read` self-dispatch). Builds new
    content = parent's content + `name: new_name` + `parent_template_uri:
    self_uri` + refreshed `created_by`/`created_at`. Kind-specific URI
    construction + owner-cap grant happen via the dispatcher on
    `ctx[:kind_module]`:
    - **SessionTemplate fork** → new URI is `template://session/<ws>/<new_name>@<hash>`
      (hash recomputed over fork content); a fork inherits the parent's
      workspace.
    - **AgentTemplate fork** → new URI is `template://agent/<ws>/<new_name>`
      (versionless); a fork inherits the parent's workspace.
    Cap preflight is handled by **dispatch CapBAC** against the parent's
    URI + `:fork` subject — a caller holding `Behavior.Template` on the
    parent's workspace is authorized (the `:fork` cap_subject is for
    documentation; matches by Behavior, not action). Returns
    `{:ok, %{template_uri: new_uri}, effects}`.

  ## Relationship to `Ezagent.Kind.Template`

  `Ezagent.Kind.Template` (`template_name/0` + `validate/1` +
  `instantiate/3`) keeps its existing role — the **Template-CLASS**
  contract plugin Template Classes implement (`CcAgent` implements it).
  `Ezagent.ActionSet.Template` is a different thing: a **Behavior on the
  Template KIND** that holds + serves the persistent content slice and
  routes dispatchable actions. The `:instantiate` action *delegates to*
  a `Ezagent.Kind.Template` Class — it does not replace it.

  ## Migration note (P2-a r3, 2026-05-28)

  Migrated to the new SPEC 2026-05-28 action grammar. `:write` /
  `:instantiate` mutate the slice via `{:set, :content, value}`
  effects; `:fork` calls Router.dispatch in-handler for the followup
  `:write` + `identity.grant_cap` (because their results are needed
  for error monadics) and returns the slice unchanged from the
  PARENT's perspective (the fork's content lives on a different Kind
  instance, written via the in-handler dispatch).

  ## Lifecycle migration (Phase B, SPEC 2026-05-29 §2.3 — the
  ## pure-state, no-transients case)

  Converted from `use Ezagent.ActionSet` to `use Ezagent.Lifecycle`. The
  `:template` slice is ENTIRELY persistent — its one field `:content` is
  the durable template record that MUST survive a restart (both Template
  Kinds are `{:snapshot, :on_change}`). There are NO transients (no PID /
  ref / ETS / port / subprocess / monitor), so:

  - `init_slice/1` → `create/1`: build the persistent `%{content: ...}`
    once, reading `args[:content]` (default `nil` for an unpopulated
    template Kind).
  - `activate/2` is the macro-injected no-op default (nothing transient
    to rebuild).
  - The hand-rolled `def state_slice` is gone — the macro auto-derives
    `Ezagent.ActionSet.Template` → `:template`, the pre-Lifecycle key, so
    no `state_slice:` override is needed (SPEC §5 step 2 / §7 OQ-7).

  Handlers are unchanged: `:read` / `:write` / `:instantiate` / `:fork`
  keep their `ctx[:read]` slice access + `{:set, :content, _}` effects +
  in-handler `Router.dispatch` for the result-dependent fork followups
  (the canonical "result-dependent in-handler dispatch" pattern §10 /
  `Chat.handle_send/2`). `data_owner/1` passes through unchanged.

  Naming (§11 NP-1/NP-2/NP-3 audit): `Ezagent.ActionSet.Template` — a
  domain module naming its own domain concept (`Template`), four actions
  whose intent the name tracks. NO violation; a rename would touch the
  `:template` snapshot key + every dispatch call site for no gain.
  Kept as-is.
  """

  use Ezagent.Lifecycle

  require Logger

  alias Ezagent.Cmd
  alias Ezagent.Entity.{AgentTemplate, SessionTemplate}

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Template is registered on both AgentTemplate AND SessionTemplate
  # Kinds — kind axis is `:any` per check 11(b)'s multi-Kind escape.
  # template:// URIs are cross-cutting (workspace_uri segment is :any
  # at the scheme level), so workspace_scoped? = false.

  action(:read,
    args: %{},
    returns: %{content: :map},
    caps: [:read],
    modes: [:call],
    description: "read the template's content + metadata (write_count, last_version_hash)",
    workspace_scoped?: false
  )

  action(:write,
    args: %{content: :map},
    returns: %{content: :map},
    caps: [:write],
    modes: [:call],
    description: "write a new immutable version of the template (CAS-keyed)",
    workspace_scoped?: false
  )

  action(:instantiate,
    args: %{
      instance_name: {:option, :string},
      workspace_uri: {:option, :uri},
      spawned_by: {:option, :uri}
    },
    returns: %{workers: {:list, :uri}, fresh?: :boolean},
    caps: [:instantiate],
    modes: [:call],
    description: "instantiate this template into a live Kind (Session / Agent / …)",
    workspace_scoped?: false
  )

  action(:fork,
    args: %{new_name: :string, owner: {:option, :uri}},
    returns: %{template_uri: :uri},
    caps: [:fork],
    modes: [:call],
    description:
      "fork this template into a NEW Template Kind whose `parent_template_uri` " <>
        "points back at this one (PR1 2026-05-24)",
    workspace_scoped?: false
  )

  # `init_slice/1` → `create/1` (SPEC §3 mapping). Build the persistent
  # `%{content: ...}` once, on first-ever existence. `:content` survives
  # restart (durable template record), so it lives in `state`; there are
  # no transients, so `activate/2` is the macro no-op default.
  # `state_slice/0` is auto-derived to `:template` (the pre-Lifecycle key).
  @impl Ezagent.Lifecycle
  def create(args) do
    {:ok, %{content: Map.get(args, :content)}}
  end

  # --- :read -------------------------------------------------------------

  def handle_read(_args, ctx) do
    content = ctx[:read].(:content, nil)
    {:ok, %{content: content}, []}
  end

  # --- :write ------------------------------------------------------------

  def handle_write(%{content: content}, ctx) when is_map(content) do
    case Map.get(ctx, :kind_module) do
      SessionTemplate ->
        write_session_template(content, ctx)

      AgentTemplate ->
        # AgentTemplate URIs are versionless — plain mutable replace.
        {:ok, %{content: content}, [{:set, :content, content}]}

      other ->
        {:error, {:template_write_unsupported_for_kind, other}}
    end
  end

  # --- :fork -------------------------------------------------------------

  # Allen 2026-05-24 PR1 — fork lifted out of `SessionTemplate.fork/3` so
  # every Template Kind gets fork for free. Runs IN-PROCESS with the
  # parent's slice already in hand (NO `:read` self-dispatch — same
  # deadlock-avoidance pattern as `:instantiate`).
  #
  # Kind-specific URI construction + owner-cap grant happen via the
  # branch on `ctx[:kind_module]`. Cap preflight is delegated to the
  # dispatch CapBAC against the parent URI (caller holding
  # `Behavior.Template` on the parent's workspace is authorized).
  def handle_fork(args, ctx) do
    case Map.get(ctx, :kind_module) do
      SessionTemplate ->
        fork_session_template(args, ctx)

      AgentTemplate ->
        fork_agent_template(args, ctx)

      other ->
        {:error, {:template_fork_unsupported_for_kind, other}}
    end
  end

  # --- :instantiate ------------------------------------------------------

  # codex rev-5 HIGH-2 — `:instantiate` runs IN-PROCESS with the slice
  # already in hand. It NEVER dispatches `:read` back to its own Kind
  # process (a self-`GenServer.call` deadlock).
  def handle_instantiate(args, ctx) do
    case Map.get(ctx, :kind_module) do
      AgentTemplate ->
        instantiate_agent_template(args, ctx)

      SessionTemplate ->
        # SessionTemplate instantiation IS the Generator
        # (`Session.spawn_from_template/2`, PR-4). The Behavior does
        # not duplicate it.
        {:error, :use_generator}

      other ->
        {:error, {:template_instantiate_unsupported_for_kind, other}}
    end
  end

  # --- internals ---------------------------------------------------------

  # SessionTemplate `:write` — write-once + hash-checked (codex rev-5
  # CRITICAL). A SessionTemplate version is content-addressed: the
  # `@<hash>` segment of its URI MUST equal the recomputed hash of the
  # content being written, and an already-populated slice may not be
  # divergently overwritten.
  defp write_session_template(content, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    existing_content = ctx[:read].(:content, nil)

    with {:ok, uri_hash} <- uri_hash_segment(self_uri),
         :ok <- check_hash_matches(content, uri_hash),
         :ok <- check_immutable(existing_content, content) do
      {:ok, %{content: content}, [{:set, :content, content}]}
    end
  end

  # The hash check: recompute over `content`, require == the URI's
  # `@<hash>` segment. URI ↔ content must agree.
  defp check_hash_matches(content, uri_hash) do
    if SessionTemplate.compute_version_hash(content) == uri_hash do
      :ok
    else
      {:error, :hash_mismatch}
    end
  end

  # The immutable-version check: a `:write` to an already-non-empty
  # `:template` slice is rejected UNLESS the new content is **logically
  # identical** — an idempotent retry, which no-ops as success.
  #
  # "Logically identical" is **content-hash equivalence**, NOT exact map
  # equality (Phase 7 completion PR-5). A SessionTemplate version is
  # content-addressed: its identity is `compute_version_hash/1`, which
  # excludes `name` / `created_at` / `created_by` / `version_*` (SPEC
  # §1.3). Two `save_template_as` retries of the same team config carry
  # different `created_at` timestamps but compute the SAME hash — so
  # they ARE the same version and the second write must no-op as `:ok`.
  # Exact map equality would spuriously reject the retry as
  # `:immutable_version`. A genuine hash divergence is already caught by
  # `check_hash_matches/2` against the URI, so this check only ever sees
  # hash-equal content here; the comparison is belt-and-braces.
  defp check_immutable(nil, _new), do: :ok

  defp check_immutable(existing, new) do
    if SessionTemplate.compute_version_hash(existing) ==
         SessionTemplate.compute_version_hash(new) do
      :ok
    else
      {:error, :immutable_version}
    end
  end

  # Extract the `@<hash>` segment from a SessionTemplate URI's name
  # path segment: `template://session/<ws>/<name>@<hash>`.
  defp uri_hash_segment(%URI{} = uri) do
    case uri |> Ezagent.URI.name!() |> String.split("@", parts: 2) do
      [_name, hash] when hash != "" -> {:ok, hash}
      _ -> {:error, :missing_version_hash_in_uri}
    end
  end

  defp uri_hash_segment(_), do: {:error, :missing_version_hash_in_uri}

  # AgentTemplate `:instantiate` — resolve flavor → Class, build the
  # Class data map, hand off to the in-process spawn helper (§1.6a). NO
  # `:read` self-dispatch.
  #
  # codex round-5 MEDIUM-3 — `spawn_from_template_content/4` now returns
  # `%{workers: ..., fresh?: ...}`; the `fresh?` flag is threaded into
  # the action result so `update_agent_template` can reject silently
  # adopting an already-live worker.
  defp instantiate_agent_template(args, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    content = ctx[:read].(:content, nil)

    case content do
      content when is_map(content) ->
        with {:ok, instance_uri} <- resolve_instance_uri(content, args, self_uri, ctx),
             {:ok, workspace_uri} <- resolve_workspace_uri(content, args, self_uri),
             spawned_by <- resolve_spawned_by(args, ctx),
             {:ok, spawn_result} when is_map(spawn_result) <-
               Ezagent.Domain.Agent.materialize_from_template(
                 content,
                 instance_uri,
                 spawned_by,
                 workspace_uri,
                 caller: Map.get(ctx, :caller),
                 caps: Map.get(ctx, :caps),
                 source_template_uri: self_uri,
                 explicit_source: Map.get(args, :explicit_source)
               ) do
          # codex PR #408 review HIGH-3 — pass through role_degraded
          # keys (if any) so callers (Session.ensure_orchestrator) can
          # surface the failure to the session owner per Invariant #9.
          result =
            spawn_result
            |> Map.take([
              :workers,
              :fresh?,
              :role_degraded,
              :role_degraded_reason,
              # #17 (c) — OAuth credential-staleness reminder, same passthrough.
              :credential_stale,
              :credential_stale_reason
            ])

          {:ok, result, []}
        end

      _ ->
        {:error, :template_not_populated}
    end
  end

  # The per-instance agent URI. The caller (Generator / add_agent_slot)
  # supplies `instance_name`; the URI is built in the resolved workspace.
  # PR-E: the name carries NO flavor prefix — flavor is stored template content,
  # read via `UriQuery.resolve(:flavor, _)`, never encoded in the URI name.
  defp resolve_instance_uri(content, args, self_uri, ctx) do
    with {:ok, workspace_uri} <- resolve_workspace_uri(content, args, self_uri) do
      workspace_name = Ezagent.URI.workspace_name!(workspace_uri)

      case Map.get(args, :instance_name) do
        name when is_binary(name) and name != "" ->
          {:ok, Ezagent.URI.agent(workspace_name, name)}

        _ ->
          {:error, {:missing_instance_name, kind: Map.get(ctx, :kind_module)}}
      end
    end
  end

  # The instantiation-destination workspace URI.
  #
  # codex HIGH-1 — a `template.instantiate` is CapBAC-checked against
  # the AgentTemplate's OWN URI (`template://agent/<workspace>/<name>`),
  # so only that workspace segment is authorized. The destination
  # workspace is therefore derived SOLELY from `self_uri` — an explicit
  # `args.workspace_uri` is NEVER trusted as the spawn destination.
  #
  # Cross-workspace instantiation is not a V1 feature: if `args` still
  # carries a `workspace_uri` that differs from the AgentTemplate's own
  # workspace, the call is REJECTED `{:error, :cross_workspace_denied}`
  # — no second-cap path. A matching (or absent) `workspace_uri` arg is
  # allowed; the worker is spawned + bound ONLY in the cap-checked
  # workspace.
  defp resolve_workspace_uri(_content, args, %URI{} = self_uri) do
    case Ezagent.Capability.workspace_of(self_uri) do
      %URI{} = authorized_ws ->
        check_workspace_arg(Map.get(args, :workspace_uri), authorized_ws)

      :any ->
        {:error, :cannot_derive_workspace}
    end
  end

  defp resolve_workspace_uri(_content, _args, _self_uri), do: {:error, :cannot_derive_workspace}

  # No explicit `workspace_uri` arg → use the cap-checked workspace.
  defp check_workspace_arg(nil, authorized_ws), do: {:ok, authorized_ws}

  # An explicit `workspace_uri` arg is allowed ONLY when it equals the
  # AgentTemplate's own (cap-checked) workspace. Any other value is a
  # workspace-escape attempt → reject.
  defp check_workspace_arg(%URI{} = requested, %URI{} = authorized_ws) do
    if same_workspace?(requested, authorized_ws) do
      {:ok, authorized_ws}
    else
      {:error, :cross_workspace_denied}
    end
  end

  defp check_workspace_arg(_other, _authorized_ws), do: {:error, :cross_workspace_denied}

  # Normalize both sides through `workspace_of/1` so a caller may pass
  # either a `workspace://<name>` URI or any per-tenant URI that
  # carries the workspace — comparison is on the canonical workspace
  # URI, never on raw string equality.
  defp same_workspace?(%URI{} = a, %URI{} = b) do
    case {Ezagent.Capability.workspace_of(a), Ezagent.Capability.workspace_of(b)} do
      {%URI{} = wa, %URI{} = wb} -> URI.to_string(wa) == URI.to_string(wb)
      _ -> false
    end
  end

  # The principal authorizing the spawn (recorded in AgentLineage).
  # Prefer the explicit arg; fall back to the dispatch caller.
  defp resolve_spawned_by(%{spawned_by: %URI{} = uri}, _ctx), do: uri
  defp resolve_spawned_by(_args, ctx), do: Map.get(ctx, :caller)

  # --- :fork internals --------------------------------------------------

  # PR1 2026-05-24 — both Kind branches share the same shape:
  #   1. validate args.new_name + parent's slice content + self_uri
  #   2. build fork content = parent content + name + parent_template_uri
  #      + created_by/created_at (+ Kind-specific resets like version_tag)
  #   3. compute Kind-specific destination URI
  #   4. ensure new Kind alive + dispatch `:write` (with CALLER's ctx)
  #   5. grant owner cap (default: caller) on the destination workspace
  #
  # The cross-Kind orchestration lives in Behavior.Template instead of
  # the Kind module (Allen 2026-05-24 — fork is a generic Template-Kind
  # concern, not Kind-specific). Each Kind branch just supplies its own
  # URI builder + cap-shape + version-field reset.

  defp fork_session_template(args, ctx) do
    parent_content = ctx[:read].(:content, nil)

    with {:ok, parent_content} <- fetch_slice_content(parent_content),
         {:ok, new_name} <- fetch_string_arg(args, :new_name),
         {:ok, %URI{} = parent_uri} <- fetch_self_uri(ctx),
         {:ok, %URI{} = workspace_uri} <- workspace_uri_of(parent_uri) do
      caller_uri = Map.get(ctx, :caller)
      owner_uri = Map.get(args, :owner, caller_uri)

      content =
        parent_content
        |> Map.put(:name, new_name)
        |> Map.put(:parent_template_uri, parent_uri)
        # SessionTemplate is content-addressed — clearing the tag is
        # required so the new content's hash is stable (matches the
        # behavior of `SessionTemplate.fork/3` pre-lift).
        |> Map.put(:version_tag, nil)
        |> Map.put(:created_by, caller_uri)
        |> Map.put(:created_at, DateTime.utc_now())

      with {:ok, new_uri} <- persist_session_template_version(content, workspace_uri, ctx),
           :ok <- grant_session_template_owner_cap(owner_uri, workspace_uri) do
        {:ok, %{template_uri: new_uri}, []}
      end
    end
  end

  defp fork_agent_template(args, ctx) do
    parent_content = ctx[:read].(:content, nil)

    with {:ok, parent_content} <- fetch_slice_content(parent_content),
         {:ok, new_name} <- fetch_string_arg(args, :new_name),
         {:ok, %URI{} = parent_uri} <- fetch_self_uri(ctx),
         {:ok, %URI{} = workspace_uri} <- workspace_uri_of(parent_uri) do
      caller_uri = Map.get(ctx, :caller)
      owner_uri = Map.get(args, :owner, caller_uri)

      workspace_name = Ezagent.URI.workspace_name!(workspace_uri)
      new_uri = Ezagent.URI.template(workspace_name, :agent, new_name)

      content =
        parent_content
        |> Map.put(:name, new_name)
        |> Map.put(:parent_template_uri, parent_uri)
        |> Map.put(:created_by, caller_uri)
        |> Map.put(:created_at, DateTime.utc_now())

      with {:ok, _pid} <- ensure_kind_alive(new_uri),
           {:ok, _result} <- dispatch_template_write(new_uri, content, ctx),
           :ok <- grant_agent_template_owner_cap(owner_uri, workspace_uri) do
        notify_fork_owner(owner_uri, parent_uri, new_uri)
        {:ok, %{template_uri: new_uri}, []}
      end
    end
  end

  # Notifier/flash audit 2026-05-24 — todo.md "Notifications consumer
  # coverage" — surface a successful AgentTemplate fork to the new
  # template's owner. Gated by `user_uri?/1`: an agent-owned fork
  # (orchestrator forking on behalf of itself) generates no
  # notification. Wrapped so a notify failure never bubbles up past
  # the action result — the fork itself already succeeded by this
  # point and the owner-cap grant landed.
  defp notify_fork_owner(%URI{} = owner_uri, %URI{} = parent_uri, %URI{} = new_uri) do
    if user_uri?(owner_uri) do
      try do
        _ =
          Ezagent.Notifications.notify(owner_uri, %{
            type: :agent_template_forked,
            body: %{
              text:
                "AgentTemplate forked: #{URI.to_string(parent_uri)} → " <>
                  URI.to_string(new_uri),
              parent_template_uri: parent_uri,
              new_template_uri: new_uri
            },
            source: __MODULE__
          })
      rescue
        error ->
          # Codex r1 MED (med-batch 2026-05-26) — P27 server-side
          # observability: rescue keeps fork success non-blocking
          # (owner-cap already granted, new template already
          # persisted) but the operator must be able to debug
          # "user forked a template, never got notified".
          Logger.warning(
            "Ezagent.ActionSet.Template: :agent_template_forked notify to " <>
              "#{URI.to_string(owner_uri)} raised #{inspect(error)}; " <>
              "fork #{URI.to_string(parent_uri)} → #{URI.to_string(new_uri)} proceeds"
          )

          :ok
      catch
        kind, reason ->
          Logger.warning(
            "Ezagent.ActionSet.Template: :agent_template_forked notify to " <>
              "#{URI.to_string(owner_uri)} threw #{inspect({kind, reason})}; " <>
              "fork #{URI.to_string(parent_uri)} → #{URI.to_string(new_uri)} proceeds"
          )

          :ok
      end
    end

    :ok
  end

  defp notify_fork_owner(_, _, _), do: :ok

  defp user_uri?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
  defp user_uri?(_), do: false

  # Shared shape helpers ---------------------------------------------------

  defp fetch_slice_content(content) when is_map(content), do: {:ok, content}
  defp fetch_slice_content(_), do: {:error, :template_not_populated}

  defp fetch_string_arg(args, key) do
    case Map.get(args, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  defp fetch_self_uri(ctx) do
    case Map.get(ctx, :self_uri) do
      %URI{} = uri -> {:ok, uri}
      _ -> {:error, :missing_self_uri}
    end
  end

  defp workspace_uri_of(%URI{} = uri) do
    case Ezagent.Capability.workspace_of(uri) do
      %URI{} = ws -> {:ok, ws}
      _ -> {:error, :cannot_derive_workspace}
    end
  end

  defp ensure_kind_alive(uri) do
    case Ezagent.SpawnRegistry.spawn(uri) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end

  # In-handler Router.dispatch — `:write` needs to succeed before we
  # grant the owner cap (let-it-crash error monadics), so we cannot
  # express it as a `:dispatch` effect (effect executor discards the
  # return value).
  defp dispatch_template_write(uri, content, ctx) do
    Ezagent.Router.dispatch(%Cmd{
      target: uri,
      action: :write,
      args: %{content: content},
      ctx: ctx
    })
  end

  # SessionTemplate-specific helpers --------------------------------------

  # Persist a new SessionTemplate version using the existing module helper
  # — that path already handles the content-hash URI construction +
  # write-once semantics correctly (HIGH-9 caller-threaded variant).
  defp persist_session_template_version(content, %URI{} = workspace_uri, ctx) do
    SessionTemplate.persist_version(content, workspace_uri,
      caller: Map.get(ctx, :caller),
      caps: Map.get(ctx, :caps)
    )
  end

  # Mirror of `SessionTemplate.grant_owner_template_cap/2` — we cannot
  # call the private function so the logic lives here. The grant is
  # idempotent across forks (CapBAC dedupes), so a fork by an existing
  # template-owner is a harmless no-op grant.
  defp grant_session_template_owner_cap(%URI{} = owner_uri, %URI{} = workspace_uri) do
    cap = %Ezagent.Capability{
      kind: :session_template,
      behavior: __MODULE__,
      # SPEC 2026-05-27 capability-action-axis — fork owner gets full
      # lifecycle authority (read/write/instantiate/fork). The
      # `:within_workspace` instance scope is the structural narrow.
      action: :any,
      instance: {:within_workspace, workspace_uri},
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: DateTime.utc_now()
    }

    grant_cap(owner_uri, cap)
  end

  defp grant_session_template_owner_cap(_, _), do: :ok

  # AgentTemplate-specific helpers ----------------------------------------

  defp grant_agent_template_owner_cap(%URI{} = owner_uri, %URI{} = workspace_uri) do
    cap = %Ezagent.Capability{
      kind: :agent_template,
      behavior: __MODULE__,
      # SPEC 2026-05-27 capability-action-axis — AgentTemplate fork
      # owner gets full lifecycle authority within the workspace.
      action: :any,
      instance: {:within_workspace, workspace_uri},
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: DateTime.utc_now()
    }

    grant_cap(owner_uri, cap)
  end

  defp grant_agent_template_owner_cap(_, _), do: :ok

  # Generic owner-cap grant — routes through the grant chokepoint
  # (SPEC 2026-06-17 §4 PR-2, site #9). The WHO-may-fork authority was
  # already enforced by dispatch CapBAC against the parent URI's `:fork`
  # action; this is purely the followup grant so the owner can later
  # operate on the fork. The cap is `<*_template>/Template/:any/
  # {:within_workspace}` — concrete kind + behavior, scope-bounded
  # instance — so `IdentityAdmin.rule_cap_bounded?/1` is true → the
  # `{:rule, …}` branch authorizes it (Decision #154). The configurer of
  # the fork-materialization rule is the OWNER (also the entity
  # `granted_by`); `template-materialize` is no longer the authorizer.
  defp grant_cap(%URI{} = owner_uri, %Ezagent.Capability{} = cap) do
    Ezagent.Identity.Grant.grant_cap_via_router(
      owner_uri,
      cap,
      {:rule, :template_materialize, owner_uri},
      :sync
    )
  end

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): workspace-scoped
  # Behavior — workspace admin grants. `:any` return signals
  # "class-wide cap, grantable by workspace admin via §5.2 admin branch".
  def data_owner(_), do: :any
end
