defmodule Ezagent.Domain.Agent do
  @moduledoc """
  Flavor-agnostic Agent lifecycle facade. Domain-layer single entry
  point for asking "what's the lifecycle status of this agent?" — UI
  surfaces (`AgentDetailLive`, etc.) call this instead of reaching
  into plugin internals.

  Per `ezagent-developer` skill invariant 8 (plugin authoring
  contract): Domain UI MUST NOT import Plugin module functions. This
  facade is the sanctioned boundary.

  ## Why this lives in `ezagent_domain_session`

  Domain.Agent is the unifying domain model over the various agent
  flavors (cc, echo, curl, future). The Agent Kind itself lives in
  `Ezagent.Entity.Agent` here in `ezagent_domain_session`, so the facade
  belongs in the same app. Domain.Agent asks domain primitives, not
  plugin modules. A live `Ezagent.Domain.Pty` sidecar means the agent
  is PTY-backed, regardless of whether the flavor is cc, codex,
  echo-with-pty, or a future plugin.

  ## Domain.Pty PR-A (2026-05-21 SPEC v1)

  Lifecycle now queries `Ezagent.Domain.Pty.alive?/1` instead of
  hardcoding cc as the only PTY-backed flavor. Code.ensure_loaded?
  still guards in case ezagent_domain_pty isn't loaded (test isolation
  contexts); the dep graph makes it always loaded in production builds.

  ## V2 (deferred)

  Per `docs/futures/v2-feedback-log.md` (Architecture gap — No
  auto-trigger from URI registration to associated template
  instantiate): the V2 path is a generic `Ezagent.ActionSet.Terminable`
  contract carried by every "running" Kind, dispatched via
  `?action=lifecycle.phase`. For V1 the facade reads flavor through
  `Ezagent.UriQuery`; flavor is stored agent metadata, not a URI name
  convention. The response shape is forward-compatible.
  """

  @type phase :: :registered | :instantiated | :alive | :error | :not_found
  @type flavor :: String.t() | nil
  @type status :: %{
          phase: phase(),
          flavor: flavor(),
          detail: map() | nil
        }

  @typedoc """
  Authz context for the non-activating read interface — mirrors the slice of the
  live dispatch `ctx` the two-route authz consumes (SPEC §2/§3.2): the
  authenticated caller URI plus the caller's optional INLINE caps (`ctx.caps`-
  shaped). `caps` defaults to `[]` (most callers carry none; inline-self-
  authority workers — e.g. the deleted `system://worker-publish` principal's
  replacement per Decision #154 — carry theirs here).
  """
  @type read_ctx :: %{
          required(:caller) => URI.t(),
          optional(:caps) => MapSet.t() | [Ezagent.Capability.t()]
        }

  @doc """
  Return the unified lifecycle status of `agent_uri`.

  Returns `%{phase: :not_found, flavor: <stored>, detail: nil}` if
  no Kind is registered at the URI.

  ## Phases

  - `:alive`        — Kind is registered. If a domain sidecar such as
                      PtyServer is running, `detail` carries its status.
  - `:registered`   — reserved for future deeper lifecycle states.
  - `:not_found`    — No KindRegistry entry for the URI.
  - `:instantiated` — (reserved for future use; not emitted by V1
                      pattern-match path).
  - `:error`        — Lifecycle helper raised / returned an error
                      atom while introspecting.
  """
  @spec lifecycle_status(URI.t()) :: status()
  def lifecycle_status(%URI{} = agent_uri) do
    flavor = resolve_flavor!(agent_uri)

    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, _pid} ->
        delegate_alive_status(flavor, agent_uri)

      :error ->
        %{phase: :not_found, flavor: flavor, detail: nil}
    end
  end

  # ── domain primitive lifecycle detection ─────────────────────────

  defp delegate_alive_status(flavor, agent_uri) do
    try do
      if Code.ensure_loaded?(Ezagent.Domain.Pty) and Ezagent.Domain.Pty.alive?(agent_uri) do
        %{phase: :alive, flavor: flavor, detail: Ezagent.Domain.Pty.status(agent_uri) || %{}}
      else
        %{phase: :alive, flavor: flavor, detail: %{}}
      end
    catch
      _, reason ->
        %{phase: :error, flavor: flavor, detail: %{error: inspect(reason)}}
    end
  end

  # ── unified non-activating read interface (SPEC unified-non-activating-
  #    agent-read.md §2) ──────────────────────────────────────────────
  #
  # ONE interface for "read agent X's config / caps / sandbox / status WITHOUT
  # activating it". A thin AUTHORIZE-then-DELEGATE layer (D2): the actual slice
  # reads stay in their owning, already-non-activating facades —
  #   config  → Ezagent.Agent.Config.read_cascade/4  (pure-DB ConfigEvolve)
  #   caps    → Ezagent.Identity.read_entity_caps/1   (live slice → snapshot)
  #   sandbox → Ezagent.ActionSet.Sandbox.read_persisted_state/1 (live → snapshot)
  #   status  → lifecycle_status/1 (KindRegistry.lookup + guarded Domain.Pty)
  # so the de-activation machinery is DRY at one site per slice and every
  # sensitive slice read stays at its allowlisted owner. Domain.Agent adds the
  # UNIFORM two-route authz preflight; it adds NO raw slice access and NEVER
  # hand-rolls the cap-shape match — that runs through the sanctioned chokepoint
  # owner `Ezagent.Identity.caps_authorize?/2` (SPEC §3.1). The §8.9 module-
  # scoped test asserts this source carries zero hand-rolled match calls.
  #
  # The two authz routes (SPEC §3.2, Decision D3) are BOTH permanent and OR'd
  # exactly as the live dispatch step-5.5 does:
  #   route 1 — the caller's INLINE `ctx.caps` (inline self-authority, #154)
  #   route 2 — the caller's slice-backed caps, read NON-ACTIVATINGLY
  #             (`read_entity_caps/1`: live slice → snapshot fallback)
  # Implementing only one route would silently lock out one caller class
  # (an inline-self-authority worker, or a logged-in user with a cold Kind).

  @doc """
  Read `agent_uri`'s full config cascade WITHOUT activating it.

  Authorize-then-delegate to the already-non-activating
  `Ezagent.Agent.Config.read_cascade/4` (pure-DB `ConfigEvolve.build_cascade/2`).
  The manage-cap gate (`cap(:agent, Manage, :read_cascade)`, instance-scoped) is
  preserved via the two-route authz (§3.2): the caller's inline `ctx.caps` OR
  its slice/snapshot caps must satisfy the needed cap.
  """
  @spec read_config(URI.t(), read_ctx(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_config(%URI{} = agent_uri, %{caller: _} = ctx, opts \\ []) do
    Ezagent.Agent.Config.read_cascade(agent_uri, ctx.caller, two_route_caps(ctx), opts)
  end

  @doc """
  Read ONE config `key` from `agent_uri`'s cascade WITHOUT activating it.

  Same gate + delegation as `read_config/3` (via `Agent.Config.read_key/5`).
  """
  @spec read_config_key(URI.t(), String.t(), read_ctx(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def read_config_key(%URI{} = agent_uri, key, %{caller: _} = ctx, opts \\ [])
      when is_binary(key) do
    Ezagent.Agent.Config.read_key(agent_uri, key, ctx.caller, two_route_caps(ctx), opts)
  end

  @doc """
  Read `entity_uri`'s granted caps as `[%Ezagent.Capability{}]` WITHOUT
  activating it.

  Preserves the `identity.list_caps` dispatch gate (`cap(<entity_kind>, Identity,
  :list_caps)`, instance-scoped) via the two-route authz, PLUS the self-read
  exemption the dispatch honored (`caller == entity` → `:ok` even with no cap).
  Delegates the read to the sanctioned owner `Ezagent.Identity.read_entity_caps/1`.
  """
  @spec read_caps(URI.t(), read_ctx()) :: {:ok, [Ezagent.Capability.t()]} | {:error, term()}
  def read_caps(%URI{} = entity_uri, %{caller: _} = ctx) do
    needed = %{
      kind: entity_kind_type(entity_uri),
      behavior: Ezagent.ActionSet.Identity,
      action: :list_caps,
      instance: Ezagent.URI.instance(entity_uri),
      workspace_uri: Ezagent.Capability.workspace_of(entity_uri)
    }

    if self_read?(ctx, entity_uri) or authorized?(needed, ctx) do
      {:ok, Ezagent.Identity.read_entity_caps(entity_uri)}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Read `agent_uri`'s persisted `:sandbox` state slice (`config_dir_path`,
  `template_class`, `respawn_template_data`, `pty_phase`, …) WITHOUT activating
  it.

  Preserves the `:sandbox/:read` dispatch gate (`cap(:agent, Sandbox, :read)`,
  instance-scoped, PURE cap check — NO self/data-owner disjunct, unlike caps) via
  the two-route authz. Delegates the read to the owner's non-activating reader
  `Ezagent.ActionSet.Sandbox.read_persisted_state/1`.
  """
  @spec read_sandbox(URI.t(), read_ctx()) :: {:ok, map()} | {:error, term()}
  def read_sandbox(%URI{} = agent_uri, %{caller: _} = ctx) do
    needed = %{
      kind: :agent,
      behavior: Ezagent.ActionSet.Sandbox,
      action: :read,
      instance: Ezagent.URI.instance(agent_uri),
      workspace_uri: Ezagent.Capability.workspace_of(agent_uri)
    }

    if authorized?(needed, ctx) do
      case Ezagent.ActionSet.Sandbox.read_persisted_state(agent_uri) do
        state when is_map(state) -> {:ok, state}
        _ -> {:error, :not_found}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Read `agent_uri`'s lifecycle status WITHOUT activating it. Surfaced in the
  unified interface for completeness; delegates UNCHANGED to the existing
  `lifecycle_status/1` (already `KindRegistry.lookup` + guarded `Domain.Pty`).
  A cold agent reads `%{phase: :not_found, …}` — correct, and non-activating by
  construction.
  """
  @spec read_status(URI.t()) :: status()
  def read_status(%URI{} = agent_uri), do: lifecycle_status(agent_uri)

  @doc """
  Read `agent_uri`'s NORMALIZED credential status (#160) WITHOUT activating it.

  Authorizes ONCE with the SAME cap as `read_config/3` — `cap(:agent, Manage,
  :read_cascade)`, instance-scoped, via the SAME two-route `authorized?/2`
  chokepoint — so it is provably owner + ws-admin only (no co-tenant, no
  session-member). This is the authority that keeps the #160 credential-leak
  family closed: a co-tenant WITHOUT the target's Manage cap is denied and learns
  NOTHING (no status, no config_dir) because authorization runs BEFORE any
  sandbox/slice read.

  Then probes the flavor's on-disk / on-slice login state as a TRUSTED INTERNAL
  read (`Ezagent.Agent.CredentialStatus`) — reading the persisted `:sandbox` slice
  for the credential home (file flavors) or the durable credential slice (curl),
  both non-activating. A cold agent is NEVER force-activated; it reads its durable
  slices or `:unknown`. `opts` (e.g. `:now_ms`/`:skew_ms`) is forwarded to the
  flavor probe.
  """
  @spec read_credential_status(URI.t(), read_ctx(), keyword()) ::
          {:ok, Ezagent.Agent.CredentialStatus.result()} | {:error, term()}
  def read_credential_status(%URI{} = agent_uri, %{caller: _} = ctx, opts \\ []) do
    needed = %{
      kind: :agent,
      behavior: Ezagent.ActionSet.Manage,
      action: :read_cascade,
      instance: Ezagent.URI.instance(agent_uri),
      workspace_uri: Ezagent.Capability.workspace_of(agent_uri)
    }

    if authorized?(needed, ctx) do
      config_dir = trusted_config_dir(agent_uri)
      flavor = safe_flavor(agent_uri)
      {:ok, Ezagent.Agent.CredentialStatus.classify(agent_uri, flavor, config_dir, opts)}
    else
      {:error, :unauthorized}
    end
  end

  # Trusted internal read of the persisted `:sandbox` slice's `config_dir_path`
  # (the credential home for file flavors) — reached ONLY after authorization,
  # so it does NOT re-run the `:sandbox/:read` gate. Non-activating (durable slice
  # → snapshot). `nil` for a slice/direct-spawn agent with no config dir.
  defp trusted_config_dir(%URI{} = agent_uri) do
    case Ezagent.ActionSet.Sandbox.read_persisted_state(agent_uri) do
      state when is_map(state) ->
        case Map.get(state, :config_dir_path) || Map.get(state, "config_dir_path") do
          p when is_binary(p) and p != "" -> p
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # Flavor resolution that never raises (the badge must degrade, not crash);
  # reuses the canonical `resolve_flavor!/1` (UriQuery `:flavor`, non-activating).
  defp safe_flavor(%URI{} = agent_uri) do
    resolve_flavor!(agent_uri)
  rescue
    _ -> nil
  end

  # ── two-route authz (SPEC §3.2, Decision D3) ─────────────────────
  #
  # route 1 (inline ctx.caps) OR route 2 (caller's slice/snapshot caps), both
  # matched through the sanctioned chokepoint owner `caps_authorize?/2`. The new
  # module NEVER calls the cap-shape match directly (the §8.9 module-scoped test
  # pins this; the global p3 probe allowlists the whole session dir so it cannot).
  defp authorized?(needed, ctx) do
    inline = Map.get(ctx, :caps, [])

    cond do
      # route 1 — inline self-authority (#154); the caller hands the cap inline.
      Ezagent.Identity.caps_authorize?(inline, needed) ->
        true

      # route 2 — slice/snapshot caps of the caller, read non-activatingly. Only
      # available when a concrete caller URI is present (an unauthenticated /
      # nil caller has no slice to read; it falls through to route 1 only).
      match?(%URI{}, Map.get(ctx, :caller)) and
          Ezagent.Identity.caps_authorize?(
            Ezagent.Identity.read_entity_caps(ctx.caller),
            needed
          ) ->
        true

      true ->
        false
    end
  end

  # `Agent.Config.read_cascade/4` does its OWN route-1-only `caps_authorize?`
  # internally, so to honor BOTH routes for config we feed it the UNION of the
  # caller's inline caps and its slice/snapshot caps (route 2). Idempotent: the
  # owner re-checks the same predicate against the same needed cap.
  defp two_route_caps(%{caller: caller} = ctx) do
    inline = ctx |> Map.get(:caps, []) |> Enum.to_list()
    slice = if match?(%URI{}, caller), do: Ezagent.Identity.read_entity_caps(caller), else: []
    MapSet.union(MapSet.new(inline), MapSet.new(slice))
  end

  # caps self-read exemption (SPEC §3.1): the live `identity.list_caps` dispatch
  # let an entity read its OWN caps with no held cap. Only a concrete caller URI
  # equal to the target qualifies (a nil/unauthenticated caller never self-reads).
  defp self_read?(%{caller: %URI{} = caller}, %URI{} = entity_uri),
    do: same_uri?(caller, entity_uri)

  defp self_read?(_ctx, _entity_uri), do: false

  # The entity Kind type the dispatch resolves for the needed-cap's `kind` axis
  # (e.g. `:user` / `:agent`); `:any` if undeterminable.
  defp entity_kind_type(%URI{} = entity_uri) do
    case Ezagent.URI.type(entity_uri) do
      {:ok, type} when is_binary(type) -> String.to_existing_atom(type)
      _ -> :any
    end
  rescue
    _ -> :any
  end

  defp same_uri?(%URI{} = left, %URI{} = right),
    do: URI.to_string(left) == URI.to_string(right)

  # ── subprocess phase facade (PTY-phase-state-machine 2026-05-26
  #    follow-up b codex MED-1 fix) ─────────────────────────────────

  @doc """
  Flavor-aware accessor for the subprocess `:starting | :running |
  :dead` phase introduced in PR-b.

  Routes to:

    * cc → `Ezagent.Domain.Pty.Server.phase/1`
    * np → `Ezagent.Domain.Python.Server.phase/1`
    * other → `:dead` (no subprocess concept)

  Used by operator terminal surfaces so the badge stays consistent across
  flavors. Without this facade a generic refresh would clobber the np
  `:python_phase` broadcast with a stale cc-only `Pty.Server.phase/1` lookup
  (codex round-1 MED-1).

  This is the operator-visibility companion to `lifecycle_status/1`:
  the latter is the Kind's lifecycle (`:not_found | :registered |
  :alive`), the former is the subprocess's three-state runtime phase.
  """
  @spec subprocess_phase(URI.t()) :: :starting | :running | :dead
  def subprocess_phase(%URI{} = agent_uri) do
    case resolve_flavor!(agent_uri) do
      "cc" ->
        if Code.ensure_loaded?(Ezagent.Domain.Pty.Server) do
          Ezagent.Domain.Pty.Server.phase(agent_uri)
        else
          :dead
        end

      "py" ->
        # `Ezagent.Domain.Python.Server` lives in `ezagent_domain_python`,
        # which is downstream of this app (only `ezagent_plugin_py` depends
        # on it — this flavor facade must NOT depend on a plugin's runtime).
        # py is THE python flavor (py-agent P4 — `np` is now a py-ROLE, not
        # its own flavor; the deleted `np` flavor's subprocess phase folds into
        # `py` since both back onto Domain.Python).
        # A direct call would emit a "module not available" warning at
        # compile time even though the `Code.ensure_loaded?/1` guard makes
        # the call runtime-safe. `apply/3` defers resolution to runtime —
        # same convention as `Ezagent.Plugin.publish_adapters!/2`'s
        # cross-app calls into the ExternalMirror registries.
        python_server = Ezagent.Domain.Python.Server

        if Code.ensure_loaded?(python_server) do
          apply(python_server, :phase, [agent_uri])
        else
          :dead
        end

      _other ->
        # Echo / curl / unknown flavor — no subprocess concept; the
        # LV badge falls through to "Unknown" (test handle / non-pty
        # agent). The PubSub subscription is harmless — the topic
        # never receives a broadcast because no Server publishes
        # on a non-cc/non-np agent URI.
        :dead
    end
  end

  # ── stored flavor lookup ─────────────────────────────────────────

  defp resolve_flavor!(%URI{} = agent_uri) do
    case Ezagent.UriQuery.resolve(:flavor, agent_uri) do
      {:ok, flavor} when is_binary(flavor) and flavor != "" -> flavor
      :none -> nil
      {:ok, other} -> raise ArgumentError, "invalid stored agent flavor: #{inspect(other)}"
      {:error, reason} -> raise ArgumentError, "agent flavor resolver failed: #{inspect(reason)}"
    end
  end
end
