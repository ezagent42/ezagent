defmodule Ezagent.Credential.Resolver do
  @moduledoc """
  #17 agent-provisioning-cascade PR-1 — the **domain.agent resolution core** (spec §4,
  §D2, §D4.3, §5.1, §5.2). PURE resolution: it enumerates the ordered layer set and
  selects the single credential source. It performs **NO materialization, NO file ops,
  NO config merge, and NO filesystem access** — that is PR-2's job. It returns
  *descriptors* only (which layers contribute, in order, + the chosen secret source).

  Two public entry points:

    * `resolve_layers/1` (spec §4) — given the resolution inputs, return
      `{:ok, %{config_layers: [...], secret_source: ...}}`. `config_layers` is the
      ORDERED low→high layer set (flavor-base → workspace → user → session, §D2);
      `secret_source` is the result of `pick_credential_source/1`.

    * `pick_credential_source/1` (spec §D4.3) — the credential-selection state machine
      with the **absent-vs-revoked** distinction: explicit > user > workspace-shared >
      fail-loud, where an *absent* user/workspace pointer FALLS THROUGH but a
      *present-but-unavailable* (revoked / unauthorized / deleted) selected source
      FAILS LOUD with a distinct error (no silent privilege downgrade; per
      `feedback_let_it_crash_no_workarounds`).

  And the create-time grant mint:

    * `authorize_and_mint_grant!/1` (spec §5.1) — at agent CREATE (human caller w/ caps):
      cap-check the chosen source's `sandbox.read` against the caller's caps (the existing
      `sandbox.read` seam — see `Ezagent.ActionSet.Workspace.resolve_source_config_dir/2`),
      then mint a durable `Ezagent.Credential.GrantRow` recording
      `{agent, source, approved_by, approved_scope, version}`. NEVER mints a grant under
      ANY `system://` principal's caps (codex H1 — privilege-escalation leak; a system
      principal is an authorizer, never an accountable approver entity, #154). The
      materialize-time fetch/revalidate already exist in PR-0; PR-1 only mints the grant.

  ## Why this lives in `Ezagent.Credential.*` (core)

  Resolution is a domain.agent concern (§D5), but the PR-0 cascade primitives
  (`GrantRow`, `UserDefaultSource`, `GrantCap`) all live under
  `Ezagent.Credential.*` in `ezagent_core`. Keeping the resolver in the same cohesive
  namespace + app avoids a cross-app dependency cycle (the workspace domain that drives
  CREATE depends on core, not vice-versa) and matches PR-0's now-merged placement.
  """

  alias Ezagent.Capability
  alias Ezagent.Credential.{GrantMint, GrantRow, UserDefaultSource}

  @typedoc "A single layer descriptor in the ordered config cascade (spec §D2)."
  @type layer :: %{
          required(:layer) => :flavor_base | :workspace | :user | :session,
          required(:present) => boolean(),
          required(:source) => term()
        }

  @typedoc "The pure resolved structure returned by `resolve_layers/1` (spec §4)."
  @type resolved :: %{
          required(:config_layers) => [layer()],
          required(:secret_source) => URI.t() | nil
        }

  @typedoc """
  Resolution inputs (spec §4). `workspace_uri`/`session_uri`/`explicit_source` may be
  absent (`nil`). `owner_uri` and `agent_uri` are required.
  """
  @type inputs :: %{
          required(:agent_uri) => URI.t(),
          required(:owner_uri) => URI.t(),
          optional(:workspace_uri) => URI.t() | nil,
          optional(:session_uri) => URI.t() | nil,
          optional(:explicit_source) => URI.t() | nil,
          optional(:credential_required?) => boolean(),
          optional(:source_available?) => (URI.t() -> boolean())
        }

  # ── resolve_layers ─────────────────────────────────────────────────────────

  @doc """
  Enumerate the ordered layer set (low→high) and pick the single credential source.

  Returns `{:ok, %{config_layers: [...], secret_source: ...}}` or `{:error, reason}`
  (propagated from `pick_credential_source/1` when a required credential cannot be
  resolved). The ORDER of `config_layers` is the cascade precedence (spec §D2):
  flavor-base (1) → workspace (2) → user (3) → session (4); later overrides earlier.
  Absent layers (no workspace template / no session) are still ENUMERATED with
  `present: false` so the order is invariant and the caller (PR-2) can reason about gaps.

  PURE: reads only the flavor attribute (via `UriQuery`) + the user-source pointer (via
  the PR-0 read path) + the optional injected `source_available?` predicate. No file ops.
  """
  @spec resolve_layers(inputs()) :: {:ok, resolved()} | {:error, term()}
  def resolve_layers(%{agent_uri: %URI{} = agent_uri, owner_uri: %URI{} = owner_uri} = inputs) do
    workspace_uri = Map.get(inputs, :workspace_uri)
    session_uri = Map.get(inputs, :session_uri)
    explicit = Map.get(inputs, :explicit_source)
    flavor = Map.get(inputs, :flavor) || flavor_of(agent_uri)

    config_layers = [
      %{layer: :flavor_base, present: true, source: {:flavor_base, flavor}},
      %{
        layer: :workspace,
        present: not is_nil(workspace_uri),
        source: Map.get(inputs, :workspace_layer_uri) || workspace_uri
      },
      %{layer: :user, present: true, source: Map.get(inputs, :user_layer_uri) || owner_uri},
      %{
        layer: :session,
        present: not is_nil(session_uri),
        source: Map.get(inputs, :session_layer_uri) || session_uri
      }
    ]

    case pick_credential_source(%{
           explicit_source: explicit,
           owner_uri: owner_uri,
           workspace_uri: workspace_uri,
           flavor: flavor,
           credential_required?: Map.get(inputs, :credential_required?, true),
           source_available?: Map.get(inputs, :source_available?, &default_source_available?/1)
         }) do
      {:ok, secret_source} ->
        {:ok, %{config_layers: config_layers, secret_source: secret_source}}

      {:error, _reason} = err ->
        err
    end
  end

  # ── pick_credential_source (D4.3 state machine) ────────────────────────────

  @doc """
  D4.3 credential-selection state machine. Precedence: **explicit > user >
  workspace-shared > fail-loud**, with the **absent-vs-revoked** distinction:

    1. `explicit_source` named → it MUST be available; if revoked/deleted/unauthorized →
       `{:error, {:explicit_source_unavailable, uri}}` (does NOT fall through).
    2. else user default source (the §5.2 pointer):
       * **absent** pointer → fall THROUGH to workspace-shared (normal provisioning);
       * **present** but the pointed source is unavailable → `{:error,
         {:user_source_unavailable, uri}}` (FAIL LOUD; no silent downgrade to workspace).
    3. else workspace-shared source (if present + available) → use it.
    4. else, when a credential is required → `{:error, :no_credential_source}`; when not
       required → `{:ok, nil}`.

  `source_available?` is an injected predicate `(URI.t() -> boolean())` — pure-testable
  and defaulting to the durable existence check (`Ezagent.SnapshotStore.latest/1` via
  the PR-0 convention). A source is "available" iff it currently exists and is not
  revoked; "unavailable" captures revoked / deleted / unauthorized uniformly for the
  fail-loud branch.

  `flavor` keys the §5.2 user-source pointer together with `(owner, workspace)`; when
  absent the user layer cannot be looked up and resolution falls through to
  workspace-shared.
  """
  @spec pick_credential_source(map()) :: {:ok, URI.t() | nil} | {:error, term()}
  def pick_credential_source(opts) when is_map(opts) do
    explicit = Map.get(opts, :explicit_source)
    owner_uri = Map.fetch!(opts, :owner_uri)
    workspace_uri = Map.get(opts, :workspace_uri)
    flavor = Map.get(opts, :flavor)
    required? = Map.get(opts, :credential_required?, true)
    available? = Map.get(opts, :source_available?, &default_source_available?/1)

    # The user-source lookup is injectable (returns `{:ok, uri}` | `:absent`) so the
    # state machine is pure-testable without the §5.2 DB read; defaults to the PR-0
    # `UserDefaultSource.resolve/3` read path.
    user_lookup =
      Map.get(opts, :user_source_lookup, fn -> user_source(owner_uri, workspace_uri, flavor) end)

    # Injectable like user_source_lookup (pure-testable): returns
    # `{:ok, uri} | :absent | {:error, reason}`. Default = the UriQuery seam.
    ws_lookup =
      Map.get(opts, :workspace_shared_lookup, fn ->
        workspace_shared_source(workspace_uri, flavor)
      end)

    do_pick(explicit, user_lookup, ws_lookup, required?, available?)
  end

  # 1. explicit source named — must be available, else fail loud (no fall-through).
  defp do_pick(%URI{} = explicit, _user_lookup, _ws_lookup, _required?, available?) do
    if available?.(explicit) do
      {:ok, explicit}
    else
      {:error, {:explicit_source_unavailable, explicit}}
    end
  end

  # 2/3/4. no explicit source — consult user pointer, then workspace-shared.
  defp do_pick(nil, user_lookup, ws_lookup, required?, available?) do
    case user_lookup.() do
      {:ok, %URI{} = user_src} ->
        # PRESENT user pointer: must be available — a revoked/deleted source FAILS LOUD,
        # it does NOT silently fall through to workspace-shared (§D4.3 absent≠revoked).
        if available?.(user_src) do
          {:ok, user_src}
        else
          {:error, {:user_source_unavailable, user_src}}
        end

      :absent ->
        # ABSENT user pointer: fall through to workspace-shared (normal provisioning).
        handle_workspace_shared(ws_lookup.(), required?, available?)
    end
  end

  # A PRESENT + available workspace-shared source is used (§D4.3 step 3). PR-1 has no
  # shared-source registry, so `workspace_shared_source/1` is always `:absent` today;
  # this clause is the live PR-3 hook (gated by the `@spec` union return).
  defp handle_workspace_shared({:ok, %URI{} = ws_src}, _required?, available?) do
    if available?.(ws_src) do
      {:ok, ws_src}
    else
      {:error, {:workspace_source_unavailable, ws_src}}
    end
  end

  # Step 4 — no source anywhere: fail loud when a credential is required.
  defp handle_workspace_shared(:absent, required?, _available?) do
    if required?, do: {:error, :no_credential_source}, else: {:ok, nil}
  end

  # A registered workspace-shared resolver FAILED (revoked / unauthorized / miswired) —
  # §D4.3 requires fail-loud, NOT a silent collapse to absence/no-source (codex H1).
  defp handle_workspace_shared({:error, _reason} = err, _required?, _available?), do: err

  # ── grant authorize at CREATE (spec §5.1) ──────────────────────────────────

  @doc """
  Spec §5.1 — at agent CREATE (human caller w/ caps): authorize `sandbox.read` on the
  chosen credential `source`, then mint a durable `GrantRow` for the new agent.

  #201-cred (codex r2 HIGH-5) — this is now `authorize_grant/1` + an
  IMMEDIATE generation-guarded `GrantMint.mint/3`: the recorded holder/source
  authority generations are persisted on the row (re-validated under lock at
  insertion and at every materialization fetch). The spawn path does NOT call
  this — it defers the mint to the created-winner via `authorize_grant/1` +
  the pending-grant descriptor; this entry point remains for callers that
  authorize+mint atomically in one step.

  #201-cred (codex r2 NEW-HIGH-3) — this exported entry point is NO LONGER a
  minting bypass: like every mint path it now requires the MANDATORY
  created-winner `witness` (`Ezagent.Kind.CreatedWitness`, minted only by
  `Ezagent.Kind.spawn_receipt/3`). A caller with a valid descriptor but no
  witness for the target agent (the exact bypass codex flagged — inserting a
  durable grant for any unused/existing agent URI with no `:started ∧ created?`
  proof) fail-closes with `{:error, :missing_created_winner_witness}` and writes
  nothing.

  Returns `{:ok, %GrantRow{}}` | `{:error, :missing_created_winner_witness |
  :unauthorized | {:source_unauthorized, uri} | :system_principal_forbidden |
  :authority_generation_unavailable | {:stale_authority_generation, uri} |
  term()}`. No file ops; no materialization.
  """
  @spec authorize_and_mint_grant!(map(), Ezagent.Kind.CreatedWitness.t() | nil) ::
          {:ok, GrantRow.t()} | {:error, term()}
  def authorize_and_mint_grant!(%{agent_uri: %URI{} = agent_uri} = args, witness) do
    with {:ok, pending} <- authorize_grant(args) do
      GrantMint.mint(agent_uri, pending, witness)
    end
  end

  @doc """
  Spec §5.1 authorization WITHOUT the durable write (#201-cred, codex r2
  HIGH-1/5): cap-check the chosen source's `sandbox.read` against the caller's
  caps and return a plain-data **pending-grant descriptor** recording the
  authorization — the chosen `source`, the `approved_by` principal, and the
  CURRENT holder/source authority generations the authorization was verified
  under. The descriptor is later executed by `Ezagent.Credential.GrantMint`
  at the created-winner's materialization boundary, which re-validates the
  generations under lock before inserting (a holder/source regenesis between
  this call and the mint rejects the stale mint).

  Fail-closed on generation availability: a holder or source WITHOUT a
  current active authority row cannot have its regeneration detected, so the
  authorization is refused with `:authority_generation_unavailable` (the
  cap-verification itself already requires the source's current row, and an
  accountable approver must have one).

  Cap-check: builds the needed `sandbox.read` cap for `source` the SAME way the dispatch
  does and asserts at least one of `caps` `matches?/2` it. **Refuses** when the caller is
  ANY `system://` principal (codex H1 — no source read/grant under an ambient
  system-principal's caps; a system principal is an authorizer, never an accountable
  approver entity, #154).
  """
  @spec authorize_grant(map()) :: {:ok, GrantMint.pending()} | {:error, term()}
  def authorize_grant(
        %{
          agent_uri: %URI{} = agent_uri,
          source: %URI{} = source,
          caller: %URI{} = _caller,
          authenticated_principal: %URI{} = holder,
          caps: caps
        } = args
      )
      when is_list(caps) do
    # The approver IS the cap-checked caller. A separately-supplied `approved_by` is only
    # tolerated when it equals the caller — we do NOT trust a caller-supplied approver
    # identity (codex: forged-approval / audit corruption). Delegated approval (admin
    # approves for a user) is a future feature requiring an explicit delegation cap.
    approved_by = Map.get(args, :approved_by, holder)

    cond do
      system_principal_caller?(holder) ->
        # codex H1 — never mint a credential grant under a `system://`
        # principal's caps. A system principal is an authorizer, never an
        # accountable approver entity (#154); generalized 2026-06-19 from the
        # narrow `system://agent-internal` check when that principal was
        # eliminated.
        {:error, :system_principal_forbidden}

      URI.to_string(approved_by) != URI.to_string(holder) ->
        {:error, :approver_must_be_caller}

      # Bind the grant to a SAME-TENANT agent — a grant for a source in workspace W may only
      # be minted for an agent in W (prevents cross-workspace pre-seeding). Authenticating
      # that `agent_uri` is the agent actually under creation is the create chokepoint's job
      # (#533 / PR-5); this primitive enforces the tenant invariant it can verify.
      Capability.workspace_of(agent_uri) != Capability.workspace_of(source) ->
        {:error, :agent_source_workspace_mismatch}

      not source_read_authorized?(holder, source, caps) ->
        {:error, {:source_unauthorized, source}}

      true ->
        with {:ok, holder_generation} <- current_generation(holder),
             {:ok, source_generation} <- current_generation(source) do
          {:ok,
           %{
             kind: :authorized,
             source: source,
             approved_by: approved_by,
             holder_generation: holder_generation,
             source_generation: source_generation
           }}
        end
    end
  end

  # The authorizing generations must be RECORDABLE for the mint to be
  # regeneration-guarded; an authority row that cannot be read fails closed.
  defp current_generation(%URI{} = uri) do
    case Ezagent.Cap.Authority.current_generation(uri) do
      {:ok, generation} -> {:ok, generation}
      :error -> {:error, :authority_generation_unavailable}
    end
  end

  @doc """
  Cap-check helper (exposed for the create chokepoint + tests): is `sandbox.read` on
  `source` authorized for the explicit authenticated `holder` by `caps`? Builds the
  needed-cap the SAME way the dispatch does for
  the `sandbox.read` action on an Agent Kind — `%{kind: :agent, behavior:
  Ezagent.ActionSet.Sandbox, action: :read, instance: <source>, workspace_uri: <ws>}` —
  mirroring `Ezagent.Credential.GrantCap.read_cap_for/1` (the authoritative derived-cap
  shape) rather than `cap_for_action/3` (which would force a cross-app reference to
  `Ezagent.Entity.Agent`, a downstream app from core). The unified authorizer verifies
  the signature, holder binding, and both current authority generations before matching.
  """
  @spec source_read_authorized?(URI.t(), URI.t(), [Capability.t()]) :: boolean()
  def source_read_authorized?(%URI{} = holder, %URI{} = source, caps) when is_list(caps) do
    needed = %{
      kind: :agent,
      behavior: Ezagent.ActionSet.Sandbox,
      action: :read,
      instance: Ezagent.URI.instance(source),
      workspace_uri: Capability.workspace_of(source)
    }

    match?({:ok, %Capability{}}, Ezagent.Cap.authorize(holder, caps, needed))
  end

  def source_read_authorized?(_, _, _), do: false

  # ── internals ──────────────────────────────────────────────────────────────

  # The user default credential source for (owner, ws, flavor) — the §5.2 stored
  # pointer, queried via the PR-0 read path (NOT a name convention). `:absent` when
  # unset (caller falls through); `{:ok, uri}` when present.
  #
  # Keyed on (owner, workspace, flavor): without a workspace or a flavor there is no
  # pointer to look up → `:absent` (fall through to workspace-shared).
  defp user_source(%URI{} = owner_uri, %URI{} = workspace_uri, flavor) when is_binary(flavor) do
    case Ezagent.URI.name(workspace_uri) do
      {:ok, ws_name} ->
        case UserDefaultSource.resolve(URI.to_string(owner_uri), ws_name, flavor) do
          nil -> :absent
          src when is_binary(src) -> {:ok, Ezagent.URI.new!(src)}
        end

      _ ->
        :absent
    end
  end

  defp user_source(%URI{}, _workspace_uri, _flavor), do: :absent

  # Workspace-shared service-account source (§D4.3 step 3). The lookup goes through
  # `Ezagent.UriQuery` for the `:workspace_shared_credential_source` attribute — the
  # standard cross-domain query seam. Workspace-shared sources are flavor-specific, so
  # the resolver arg is `{workspace_uri, flavor}`.
  @workspace_shared_attr :workspace_shared_credential_source

  @spec workspace_shared_source(URI.t() | nil, String.t() | nil) ::
          {:ok, URI.t()} | :absent | {:error, term()}
  defp workspace_shared_source(nil, _flavor), do: :absent
  defp workspace_shared_source(%URI{}, nil), do: :absent

  defp workspace_shared_source(%URI{} = workspace_uri, flavor) when is_binary(flavor) do
    Ezagent.UriQuery.resolve(@workspace_shared_attr, {workspace_uri, flavor})
    |> classify_workspace_shared_result()
  end

  @doc false
  # Pure classifier for the `:workspace_shared_credential_source` UriQuery result (exposed
  # @doc false for direct testing — global UriQuery registration is un-undoable so we can't
  # register a real resolver in tests). Only the EXACT dispatcher-absence shape
  # (`{:no_resolver, :workspace_shared_credential_source}` = no resolver registered for THIS
  # attr) is `:absent`; a registered resolver that reports/propagates ANY other error —
  # including `{:no_resolver, <some_dependency>}` — must FAIL LOUD per §D4.3 (codex H1),
  # never be hidden as absent.
  @spec classify_workspace_shared_result(term()) :: {:ok, URI.t()} | :absent | {:error, term()}
  def classify_workspace_shared_result({:ok, src}) when is_binary(src),
    do: {:ok, Ezagent.URI.new!(src)}

  def classify_workspace_shared_result({:ok, %URI{} = src}), do: {:ok, src}
  def classify_workspace_shared_result(:none), do: :absent

  def classify_workspace_shared_result({:error, {:no_resolver, @workspace_shared_attr}}),
    do: :absent

  def classify_workspace_shared_result({:error, reason}),
    do: {:error, {:workspace_source_unavailable, reason}}

  defp flavor_of(%URI{} = agent_uri) do
    case Ezagent.UriQuery.resolve(:flavor, agent_uri) do
      {:ok, flavor} -> flavor
      :none -> nil
      {:error, _} -> nil
    end
  end

  # Default availability: a source is available iff it currently exists as a durable
  # snapshot (the PR-0 `source_exists?` convention) — revoked/deleted sources read as
  # unavailable, driving the fail-loud branch. PR-2 layers the grant-revocation check on
  # top at materialize time; at CREATE existence is the availability signal.
  # Via the §2.2 actor read surface (C2): `read_durable/3` never spawns and
  # answers durable existence regardless of the probe slice key (`{:ok, _, _}`
  # ⟺ the old `match?({:ok, _}, SnapshotStore.latest/1)`).
  defp default_source_available?(%URI{} = source) do
    match?({:ok, _, _}, Ezagent.Kind.read_durable(source, :identity))
  end

  defp default_source_available?(source) when is_binary(source) do
    match?({:ok, _, _}, Ezagent.Kind.read_durable(source, :identity))
  end

  # System-principal elimination (#154 north star, 2026-06-19) — was
  # `uri == SystemPrincipal.uri("agent-internal")`, a guard against minting a
  # credential grant under that ONE ambient principal's blanket caps (codex
  # H1). With `system://agent-internal` deleted that exact comparison would now
  # RAISE (`SystemPrincipal.uri/1` raises on an uncataloged service), and the
  # narrow check was always under-broad anyway: per #154 NO `system://`
  # principal is a valid grant approver (a principal is an authorizer, never an
  # accountable `granted_by`). Generalize the H1 invariant to reject ANY
  # `system://`-scheme caller — same forward defense, no dependency on a
  # specific (now-eliminated) principal, and strictly more #154-aligned.
  defp system_principal_caller?(%URI{scheme: "system"}), do: true
  defp system_principal_caller?(%URI{}), do: false
end
