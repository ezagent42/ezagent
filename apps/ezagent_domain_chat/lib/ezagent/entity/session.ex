defmodule Ezagent.Entity.Session do
  @moduledoc """
  Session Kind — the "room" in Phase 2's chat routing model.

  A Session is the entity that holds a set of member URIs and routes
  outbound chat messages to them. Per Decision #61 + P2-D2 K-path:
  Session handles `:send / :join / :leave` actions; the member-side
  `:receive` action runs on the recipient Kind (User / Agent).

  Phase 2 spawns exactly one default instance — `session://default/default/main` —
  at `EzagentDomainChat.Application.start/2`. Multi-Session support is
  intentionally out of scope (Phase 3+).

  ## Persistence: {:snapshot, :on_change} — session membership survives restart

  See git history for the rationale (Allen V1 acceptance 2026-05-22) —
  the slice is now snapshotted on every change so membership +
  template_working_copy survive an unclean crash.
  """

  @behaviour Ezagent.Kind

  alias Ezagent.Routing.RuleStore

  @impl Ezagent.Kind
  def type_name, do: :session

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.Chat]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainChat.SessionSupervisor

  @doc """
  URI of the default Session instance spawned at boot.

  SPEC v3 §3.6 — sessions are 3-segment: `session://<template>/<workspace>/<name>`.
  """
  @spec default_uri() :: URI.t()
  def default_uri, do: URI.new!("session://default/default/main")

  @doc """
  Generator-reconciler refactor (SPEC `docs/superpowers/specs/2026-05-23-generator-reconciler.md`):
  `spawn_from_template/2` is now an IDEMPOTENT RECONCILER (Workspace.Loader pattern).

  Replaces the previous atomic-saga `do_spawn/4` + `cleanup_partial/1`
  scaffolding. The function converges the current system state to the
  SessionTemplate's desired-state spec; partial residue from a previous
  failed run is the EXPECTED intermediate state, and re-running with the
  same `(template_uri, owner_uri)` continues from where the prior run
  stopped.

  ## Return shape (SPEC §1.2 — three-arm)

  - `{:ok, %{session_uri, orchestrator_uri, slots}}` — full convergence.
  - `{:partial, %{session_uri, orchestrator_uri, completed, pending, errors}}` —
    one or more steps could not converge in this pass (e.g. an
    AgentTemplate's plugin hasn't booted yet). The caller may re-invoke
    with the same args to continue.
  - `{:error, reason}` — refused at preflight (auth /
    template-not-populated / cross-workspace denied / invalid input).
    No Session was created. NOT recoverable by re-running.

  ## Determinism (SPEC §7-1 — Allen-approved Option A)

  The Session URI is derived from `(SessionTemplate URI, owner URI)`
  via `derive_session_uri/3`. Re-invocation with the same `(template,
  owner)` pair always targets the same Session URI, so the reconciler
  finds existing state and skips already-converged components. V1
  trade-off: one owner cannot have two concurrent sessions from the
  same SessionTemplate — fork the template for that case.

  ## What's KEPT from the saga (rounds 1-3 hardening — security-critical)

  - Owner-cap preflight (the un-completable `:unauthorized` denial).
  - Workspace-isolation preflight (the un-completable
    `:cross_workspace_denied` denial — SessionTemplate workspace must
    equal default_workspace_uri must equal every slot AgentTemplate's
    workspace).
  - Slot-name uniqueness preflight + routing-matcher shape preflight.
  - The round-7+ `fresh?`-gated post-spawn obligations (useful inside
    the reconciler too — only fresh workers need lineage + binding).
  - The round-8 ownership-verified `fresh?: false` worker adoption
    gate (prevents silent re-parenting of a foreign worker).
  - The round-10 spawner-cleans-its-own-fresh-spawn discipline (the
    micro-atomicity at the spawn-helper level survives — only the
    Generator-level saga goes away).

  ## What's GONE

  - `do_spawn/4`'s `with`-chain wrapped in `guard/2`.
  - `cleanup_partial/1`'s 5-store teardown enumeration.
  - `terminate_kind/1` + `safe/1` helpers (only the saga called them).
  - `preflight_agent_slots/1` — moved into per-slot reconcile so a
    single un-resolvable slot becomes a `:partial` pending entry, NOT
    a Generator-wide abort (codex rev-2 HIGH-2 / SPEC §2 step 3).
  - `preflight_candidate_uris_free/3` — orphan workers ARE welcomed
    if they pass the ownership gate; otherwise the per-slot reconcile
    refuses adoption (SPEC §2 step 3, also covered by round-8 ownership
    verification).
  """
  @spec spawn_from_template(URI.t(), URI.t()) ::
          {:ok,
           %{
             session_uri: URI.t(),
             orchestrator_uri: URI.t(),
             slots: [{String.t(), URI.t()}]
           }}
          | {:partial,
             %{
               session_uri: URI.t() | nil,
               orchestrator_uri: URI.t() | nil,
               completed: [atom()],
               pending: [atom()],
               errors: [{atom(), term()}]
             }}
          | {:error, term()}
  def spawn_from_template(%URI{} = session_template_uri_in, %URI{} = owner_uri_in) do
    # Canonicalize both URIs through a parse round-trip (cap-key parity
    # — `URI.new!/1` and `URI.parse/1` produce structurally-different
    # %URI{} structs; CapBAC matching is exact struct equality).
    session_template_uri = URI.parse(URI.to_string(session_template_uri_in))
    owner_uri = URI.parse(URI.to_string(owner_uri_in))

    # ── Preflights (SPEC §2 step 0) — un-completable failures up front ──
    with {:ok, _template_pid} <- ensure_template_alive(session_template_uri),
         :ok <- owner_instantiate_preflight(session_template_uri, owner_uri),
         {:ok, template_content} <- read_template_content(session_template_uri),
         {:ok, workspace_uri} <- resolve_target_workspace(template_content),
         :ok <-
           preflight_workspace_isolation(
             session_template_uri,
             workspace_uri,
             template_content
           ),
         :ok <- preflight_slot_name_uniqueness(template_content),
         :ok <- preflight_routing_rules(template_content) do
      reconcile_loop(template_content, workspace_uri, owner_uri, session_template_uri)
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Reconcile loop — SPEC §2
  # ─────────────────────────────────────────────────────────────────────

  defp reconcile_loop(template_content, workspace_uri, owner_uri, session_template_uri) do
    # Step 1: ensure Session (deterministic URI; idempotent spawn + bind)
    case ensure_session(template_content, workspace_uri, owner_uri) do
      {:error, reason} ->
        {:error, reason}

      {:ok, session_uri, _session_outcome} ->
        # Step 2: ensure orchestrator (ownership-gated adoption)
        case ensure_orchestrator(session_uri, workspace_uri, owner_uri) do
          {:error, reason} ->
            partial_report(
              session_uri: session_uri,
              orchestrator_uri: nil,
              completed: [:session],
              pending: [:orchestrator],
              errors: [{:orchestrator, reason}]
            )

          {:partial, %{orchestrator_pending: candidate_uri} = ev} ->
            partial_report(
              session_uri: session_uri,
              orchestrator_uri: nil,
              completed: [:session],
              pending: [:orchestrator],
              errors: [{:orchestrator, {:orchestrator_ownership_pending, candidate_uri, ev}}]
            )

          {:ok, orchestrator_uri, _orch_outcome} ->
            # Step 3: reconcile each agent slot independently
            slot_results =
              reconcile_each_slot(
                template_content,
                session_uri,
                workspace_uri,
                orchestrator_uri
              )

            # Step 4: reconcile routing rules
            routing_outcome =
              reconcile_routing_rules(
                template_content,
                slot_results,
                workspace_uri,
                owner_uri
              )

            # Step 5: merge working copy (with this-pass revalidation —
            # codex rev-4 HIGH-2)
            wc_outcome =
              merge_working_copy(
                session_uri,
                template_content,
                slot_results,
                workspace_uri,
                orchestrator_uri
              )

            # Step 6: grant scoped caps (idempotent, logical-equality)
            caps_outcome =
              grant_scoped_caps_idempotent(
                orchestrator_uri,
                session_uri,
                owner_uri
              )

            # Step 7: register MCP context (ETS put; always idempotent)
            mcp_outcome =
              register_orchestrator_mcp_context(
                orchestrator_uri,
                session_uri,
                workspace_uri,
                owner_uri,
                session_template_uri
              )

            assemble_outcome(
              session_uri,
              orchestrator_uri,
              slot_results,
              routing_outcome,
              wc_outcome,
              caps_outcome,
              mcp_outcome
            )
        end
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Step 1 — ensure_session  (SPEC §2 step 1)
  # ─────────────────────────────────────────────────────────────────────

  defp ensure_session(template_content, %URI{} = workspace_uri, %URI{} = owner_uri) do
    session_uri = derive_session_uri(template_content, workspace_uri, owner_uri)

    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, _pid} ->
        # Workspace bind is idempotent (ETS upsert); call to assert.
        :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
        {:ok, session_uri, :already_present}

      :error ->
        # PR-OWN-2 (caps-data-ownership SPEC #306 §7) — pass
        # `owner_uri` into the Kind init args so `Behavior.Chat.init_slice/1`
        # records it on the `:chat` slice. `Behavior.Chat.data_owner/1`
        # reads it back via `Session.owner/1` for cap-grant authorization.
        # We bypass `Ezagent.SpawnRegistry.spawn/1` here (URI-only API)
        # to pass extra args; the SpawnRegistry fn at session_app.ex:379
        # remains the rehydrate path for lookups where owner_uri isn't
        # available (snapshot restore on phx restart).
        case Ezagent.Kind.spawn(__MODULE__, %{uri: session_uri, owner_uri: owner_uri}) do
          {:ok, _pid} ->
            :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
            {:ok, session_uri, :created}

          {:error, {:already_started, _pid}} ->
            # Won the lookup race; bind + return.
            :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
            {:ok, session_uri, :already_present}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  PR-OWN-2 (caps-data-ownership SPEC #306 §7) — return the URI of the
  entity that "owns" this session (the user/agent that created it).

  Looks up the live Session Kind's `:chat` slice via
  `Ezagent.Kind.get_slice/2`. Returns:
  - `{:ok, %URI{}}` — the owner URI recorded at session creation
  - `{:ok, nil}` — session exists but has no recorded owner
    (system session, or pre-PR-OWN-2 snapshot without `:owner_uri`)
  - `{:error, reason}` — session not live or call failed

  Used by `Behavior.Chat.data_owner/1` which converts the result
  into `%URI{} | :no_owner` for the cap-grant authorization path.
  """
  @spec owner(URI.t() | String.t()) :: {:ok, URI.t() | nil} | {:error, term()}
  def owner(uri) do
    case Ezagent.Kind.get_slice(uri, :chat) do
      {:ok, %{owner_uri: owner_uri}} -> {:ok, owner_uri}
      {:ok, nil} -> {:ok, nil}
      {:ok, _} -> {:ok, nil}
      {:error, _} = err -> err
    end
  end

  @doc """
  PR-A helper (SPEC §5 — the Kind-idempotency-enhancement table) —
  derive the deterministic Session URI for `(SessionTemplate URI,
  owner URI)`.

  V1 Option A (SPEC §7-1, Allen-approved 2026-05-23): pure determinism,
  no slug discriminator. Two concurrent sessions of the same template
  for the same owner require forking the template. The session
  workspace segment is the template's `default_workspace_uri` segment
  (already resolved by `resolve_target_workspace/1`).

  Shape: `session://<template_class>/<workspace>/<owner_name>-<template_name>`
  — `<template_class>` is the SessionTemplate's `class` field (default
  `generic` for SessionTemplates; SPEC v3 §3.6 puts template-class in
  the type axis).

  Public so the helper can be exercised directly from tests.
  """
  @spec derive_session_uri(map(), URI.t(), URI.t()) :: URI.t()
  def derive_session_uri(template_content, %URI{} = workspace_uri, %URI{} = owner_uri) do
    template_class =
      Map.get(template_content, :class) ||
        Map.get(template_content, "class") ||
        "generic"

    workspace_name = workspace_uri.host || "default"
    owner_name = derive_session_owner_segment(owner_uri)
    template_name = derive_session_template_segment(template_content)

    URI.new!(
      "session://#{template_class}/#{workspace_name}/#{owner_name}-#{template_name}"
    )
  end

  defp derive_session_owner_segment(%URI{path: "/" <> rest}) do
    case String.split(rest, "/", parts: 2) do
      [_workspace, name] when name != "" -> uri_safe(name)
      [single] -> uri_safe(single)
      _ -> "owner"
    end
  end

  defp derive_session_owner_segment(%URI{host: host}) when is_binary(host) and host != "",
    do: uri_safe(host)

  defp derive_session_owner_segment(_), do: "owner"

  defp derive_session_template_segment(template_content) do
    case Map.get(template_content, :name) || Map.get(template_content, "name") do
      n when is_binary(n) and n != "" -> uri_safe(n)
      _ -> "template"
    end
  end

  # URI-safe: collapse anything outside [a-zA-Z0-9_-] to "-".
  defp uri_safe(s) when is_binary(s) do
    s
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
    |> case do
      "" -> "x"
      out -> out
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Step 2 — ensure_orchestrator  (SPEC §2 step 2, codex rev-4 HIGH-1/3)
  # ─────────────────────────────────────────────────────────────────────

  defp ensure_orchestrator(%URI{} = session_uri, %URI{} = workspace_uri, %URI{} = owner_uri) do
    candidate_uri = derive_orchestrator_uri(session_uri, workspace_uri)
    orch_template_uri = URI.parse("template://agent/default/cc-orchestrator")
    instance_name = derive_orchestrator_instance_name(session_uri)

    case check_orchestrator(candidate_uri, owner_uri, workspace_uri) do
      {:owned, ^candidate_uri} ->
        {:ok, candidate_uri, :already_present}

      :not_live ->
        # codex rev-4 HIGH-1: NEVER call the side-effecting `Agent.spawn/4`
        # in the reconciler — that would silently re-parent any foreign
        # process that claimed the URI in the TOCTOU window. Use the
        # fresh-only `Agent.spawn_fresh/4` primitive; on `:already_started`
        # re-enter the ownership gate.
        case Ezagent.Entity.Agent.spawn_fresh(
               orch_template_uri,
               instance_name,
               workspace_uri,
               owner_uri
             ) do
          {:ok, %{fresh?: true, agent_uri: orch_uri}} ->
            {:ok, orch_uri, :created}

          {:ok, %{fresh?: false}} ->
            # Lost the race; re-classify ownership.
            retry_after_race(candidate_uri, owner_uri, workspace_uri)

          {:error, _} = err ->
            err
        end

      {:ownership_pending, _} ->
        # codex rev-4 MEDIUM-3: bounded re-read (NOT auto-classified as
        # foreign). On exhaust returns `{:partial, _}` so the operator's
        # retry is the resolution path.
        retry_after_race(candidate_uri, owner_uri, workspace_uri)

      {:foreign, evidence} ->
        # POSITIVE foreign evidence (lineage / workspace POSITIVELY
        # mismatches). Real corruption / cross-tenant collision.
        {:error, {:orchestrator_foreign, candidate_uri, evidence}}
    end
  end

  # codex rev-4 HIGH-1 fix as REAL implementation (per the user's PR-A
  # required-issues list): tail-recursive with bounded retries +
  # bounded sleep. Pre-PR-A SPEC sketch used `Stream.unfold + List.last`
  # which crashes on empty streams; reduce_while / explicit recursion
  # avoid that. 3 retries × 50ms sleep = ≤150ms total worst case.
  @retry_max 3
  @retry_sleep_ms 50

  defp retry_after_race(%URI{} = uri, %URI{} = owner_uri, %URI{} = workspace_uri) do
    do_retry(uri, owner_uri, workspace_uri, @retry_max)
  end

  defp do_retry(%URI{} = uri, _owner_uri, _workspace_uri, 0) do
    {:partial, %{orchestrator_pending: uri}}
  end

  defp do_retry(%URI{} = uri, owner_uri, workspace_uri, n) when n > 0 do
    case check_orchestrator(uri, owner_uri, workspace_uri) do
      {:owned, ^uri} ->
        {:ok, uri, :already_present}

      {:foreign, evidence} ->
        {:error, {:orchestrator_foreign, uri, evidence}}

      _ ->
        Process.sleep(@retry_sleep_ms)
        do_retry(uri, owner_uri, workspace_uri, n - 1)
    end
  end

  # 3-way classification (codex rev-4 MEDIUM-3):
  #   :owned — BOTH lineage + workspace POSITIVELY match us
  #   {:foreign, ev} — at least one POSITIVELY mismatches
  #   {:ownership_pending, _} — neither (one/both absent; spawn inflight)
  #   :not_live — KindRegistry lookup missed
  defp check_orchestrator(%URI{} = uri, %URI{} = owner_uri, %URI{} = workspace_uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error ->
        :not_live

      {:ok, _pid} ->
        lineage_state =
          case Ezagent.AgentLineage.lookup(uri) do
            {:ok, %URI{} = principal} ->
              if URI.to_string(principal) == URI.to_string(owner_uri),
                do: :match,
                else: {:mismatch, URI.to_string(principal)}

            :error ->
              :absent
          end

        workspace_state =
          case Ezagent.WorkspaceRegistry.lookup(uri) do
            {:ok, %URI{} = bound} ->
              if URI.to_string(bound) == URI.to_string(workspace_uri),
                do: :match,
                else: {:mismatch, URI.to_string(bound)}

            :error ->
              :absent
          end

        cond do
          lineage_state == :match and workspace_state == :match ->
            {:owned, uri}

          match?({:mismatch, _}, lineage_state) or match?({:mismatch, _}, workspace_state) ->
            {:foreign, %{lineage: lineage_state, workspace: workspace_state}}

          true ->
            {:ownership_pending, uri}
        end
    end
  end

  defp derive_orchestrator_uri(%URI{} = session_uri, %URI{} = workspace_uri) do
    instance_name = derive_orchestrator_instance_name(session_uri)
    workspace_name = workspace_uri.host || "default"
    URI.new!("entity://agent/#{workspace_name}/#{instance_name}")
  end

  defp derive_orchestrator_instance_name(%URI{} = session_uri) do
    # Preserve the historical "cc_orchestrator-<session_name>" shape.
    "cc_orchestrator-#{session_discriminator(session_uri)}"
  end

  # ─────────────────────────────────────────────────────────────────────
  # Step 3 — reconcile_each_slot / reconcile_slot  (SPEC §2 step 3)
  # ─────────────────────────────────────────────────────────────────────

  # Returns `[{slot_name, outcome}]` where outcome is one of:
  #   {:already_converged, agent_template_uri, worker_uri}
  #   {:ok,                agent_template_uri, worker_uri}
  #   {:error,             reason}
  defp reconcile_each_slot(
         template_content,
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = orchestrator_uri
       ) do
    slots = normalize_agent_slots(Map.get(template_content, :agent_slots, []))
    discriminator = session_discriminator(session_uri)

    Enum.map(slots, fn {slot_name, %URI{} = agent_template_uri} ->
      outcome =
        reconcile_slot(
          slot_name,
          agent_template_uri,
          discriminator,
          workspace_uri,
          orchestrator_uri
        )

      {slot_name, outcome}
    end)
  end

  defp reconcile_slot(
         slot_name,
         %URI{} = agent_template_uri,
         discriminator,
         %URI{} = workspace_uri,
         %URI{} = orchestrator_uri
       ) do
    instance_name =
      Ezagent.Entity.Agent.session_instance_name(slot_name, discriminator, 0)

    # Fast path: a worker at the expected URI already owned by us is
    # converged (lineage + workspace match). We don't even need to
    # dispatch `template.instantiate` — the structural equivalent of
    # `Workspace.Loader.bind_one_gated/3`.
    case expected_worker_uri(slot_name, agent_template_uri, instance_name, workspace_uri) do
      {:ok, worker_uri_candidate} ->
        if worker_already_owned_by_us?(worker_uri_candidate, orchestrator_uri, workspace_uri) do
          {:already_converged, agent_template_uri, worker_uri_candidate}
        else
          dispatch_slot_instantiate(
            slot_name,
            agent_template_uri,
            instance_name,
            workspace_uri,
            orchestrator_uri
          )
        end

      :unknown ->
        # We could not derive a candidate URI ahead of time (no flavor on
        # the template content yet). Dispatch and let `template.instantiate`
        # return the actual worker URI.
        dispatch_slot_instantiate(
          slot_name,
          agent_template_uri,
          instance_name,
          workspace_uri,
          orchestrator_uri
        )
    end
  end

  defp dispatch_slot_instantiate(
         slot_name,
         %URI{} = agent_template_uri,
         instance_name,
         %URI{} = workspace_uri,
         %URI{} = orchestrator_uri
       ) do
    # codex rev-2 HIGH-2: per-slot AgentTemplate aliveness is in the slot
    # reconcile (not Generator-wide preflight) — a failure here becomes
    # `:partial`, not abort.
    with {:ok, _pid} <- ensure_template_alive(agent_template_uri),
         target <-
           URI.parse("#{URI.to_string(agent_template_uri)}?action=template.instantiate"),
         {:ok, %{workers: workers, fresh?: fresh?}} <-
           Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target,
             mode: :call,
             args: %{
               instance_name: instance_name,
               workspace_uri: workspace_uri,
               spawned_by: orchestrator_uri
             },
             ctx: %{
               caller: orchestrator_uri,
               caps: Ezagent.Entity.User.admin_caps(),
               reply: {:caller_inbox, self()}
             }
           }),
         {:ok, worker_uri} <- first_worker(workers),
         :ok <-
           verify_slot_candidate_ownership(
             fresh?,
             slot_name,
             worker_uri,
             workspace_uri,
             orchestrator_uri
           ) do
      {:ok, agent_template_uri, worker_uri}
    else
      {:error, reason} ->
        {:error, {:slot, slot_name, reason}}

      other ->
        {:error, {:slot, slot_name, {:unexpected_instantiate_result, other}}}
    end
  end

  defp first_worker([%URI{} = worker_uri | _]), do: {:ok, worker_uri}
  defp first_worker([uri | _]) when is_binary(uri), do: {:ok, URI.parse(uri)}
  defp first_worker([]), do: {:error, :instantiate_returned_no_worker}

  # Try to compute the worker URI ahead of dispatch so we can fast-path
  # an already-owned worker. Reads the AgentTemplate's `flavor` field
  # without doing any spawn side effect (the AgentTemplate Kind itself
  # may need to be alive — we already lazy-spawned it via the fast-path
  # caller path; if it isn't, return `:unknown` and let the dispatch
  # path handle it).
  defp expected_worker_uri(_slot_name, %URI{} = agent_template_uri, instance_name, %URI{} = workspace_uri) do
    case agent_template_flavor(agent_template_uri) do
      {:ok, flavor} ->
        workspace_name = workspace_uri.host || "default"
        {:ok, URI.new!("entity://agent/#{workspace_name}/#{flavor}_#{instance_name}")}

      :no_flavor ->
        :unknown
    end
  end

  # codex round-8 HIGH-2 — preserved unchanged (still the ownership gate
  # for `fresh?: false` workers — orchestrator MUST match THIS one).
  defp verify_slot_candidate_ownership(true, _slot_name, _worker_uri, _workspace_uri, _orch_uri),
    do: :ok

  defp verify_slot_candidate_ownership(
         false,
         slot_name,
         %URI{} = worker_uri,
         %URI{} = workspace_uri,
         %URI{} = orchestrator_uri
       ) do
    if worker_already_owned_by_us?(worker_uri, orchestrator_uri, workspace_uri) do
      :ok
    else
      {:error, {:slot_candidate_not_owned, slot_name, URI.to_string(worker_uri)}}
    end
  end

  @doc """
  PR-A helper (SPEC §5, codex rev-3 HIGH-1) — the ownership predicate
  shared by:

    * the worker-slot fast path (skip dispatch when already owned);
    * the round-8 `fresh?: false` adoption gate;
    * the working-copy merge's "is the prior tuple still ours?" check;
    * the orchestrator-adopt gate (via `check_orchestrator/3`).

  A worker is "owned by us" iff its `AgentLineage` row points at our
  orchestrator AND its `WorkspaceRegistry` binding points at our
  workspace. URI comparison is canonical-string (registries store
  parsed structs derived from strings).
  """
  @spec worker_already_owned_by_us?(URI.t(), URI.t(), URI.t()) :: boolean()
  def worker_already_owned_by_us?(%URI{} = worker_uri, %URI{} = orch_uri, %URI{} = ws_uri) do
    case Ezagent.KindRegistry.lookup(worker_uri) do
      {:ok, _pid} ->
        lineage_ok? =
          case Ezagent.AgentLineage.lookup(worker_uri) do
            {:ok, %URI{} = sb} -> URI.to_string(sb) == URI.to_string(orch_uri)
            :error -> false
          end

        ws_ok? =
          case Ezagent.WorkspaceRegistry.lookup(worker_uri) do
            {:ok, %URI{} = bw} -> URI.to_string(bw) == URI.to_string(ws_uri)
            :error -> false
          end

        lineage_ok? and ws_ok?

      :error ->
        false
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Step 4 — reconcile_routing_rules  (SPEC §2 step 4, codex rev-2 HIGH-5)
  # ─────────────────────────────────────────────────────────────────────

  # Returns:
  #   {:ok, [rule_id]}     — all converged (some skipped as already-installed)
  #   {:partial, [{:rule, reason}], rule_ids_added}
  #   {:error, reason}
  defp reconcile_routing_rules(
         template_content,
         slot_results,
         %URI{} = workspace_uri,
         %URI{} = owner_uri
       ) do
    rules = normalize_routing_rules(Map.get(template_content, :routing_rules, []))
    slot_uri_by_name = slot_uri_map(slot_results)
    table = EzagentDomainChat.Routing.MentionRouting

    # Pre-classify each rule: :converged | {:add, ...} | {:pending, _} |
    # {:drift, %RuleRow{}} | :skip
    classifications =
      Enum.map(rules, fn {matcher_ast, slot_names} ->
        classify_routing_rule(matcher_ast, slot_names, slot_uri_by_name, workspace_uri, table)
      end)

    pending =
      Enum.flat_map(classifications, fn
        {:pending, reason} -> [{:rule, reason}]
        {:drift, row} -> [{:rule, {:rule_disabled_by_operator, row.id}}]
        _ -> []
      end)

    to_add =
      Enum.flat_map(classifications, fn
        {:add, matcher_ast, receiver_uris} -> [{matcher_ast, receiver_uris}]
        _ -> []
      end)

    case insert_routing_rules_txn(to_add, table, workspace_uri, owner_uri) do
      {:ok, []} ->
        # Nothing to add this pass.
        if pending == [],
          do: {:ok, []},
          else: {:partial, pending, []}

      {:ok, inserted_ids} ->
        case safe_load_registry(table) do
          :ok ->
            if pending == [],
              do: {:ok, inserted_ids},
              else: {:partial, pending, inserted_ids}

          {:error, reason} ->
            # Best-effort delete the rows we just inserted (registry never
            # hydrated — keep ETS clean + DB consistent).
            Enum.each(inserted_ids, fn id ->
              try_safe(fn -> RuleStore.delete(id, force: true) end)
            end)

            {:error, {:routing_install_raised, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp classify_routing_rule(matcher_ast, slot_names, slot_uri_by_name, workspace_uri, table) do
    receiver_uris =
      slot_names
      |> Enum.map(&Map.get(slot_uri_by_name, to_string(&1)))
      |> Enum.reject(&is_nil/1)

    cond do
      length(receiver_uris) != length(slot_names) ->
        # Some slot didn't resolve — defer this rule to a later pass.
        {:pending, :receivers_unresolved}

      receiver_uris == [] ->
        :skip

      true ->
        case existing_routing_rule_for(table, matcher_ast, receiver_uris, workspace_uri) do
          {:found, _row} ->
            :converged

          {:disabled, row} ->
            # Operator drift — log + classify as pending; DO NOT
            # auto-re-enable (SPEC §7-4 option A, Allen-approved).
            require Logger

            Logger.warning(
              "Generator reconciler: routing rule id=#{row.id} matches the SessionTemplate " <>
                "but is disabled by the operator — skipping (not auto-re-enabled). " <>
                "Re-enable via admin UI or remove the rule from the SessionTemplate."
            )

            {:drift, row}

          :not_found ->
            {:add, matcher_ast, receiver_uris}
        end
    end
  end

  @doc """
  PR-A helper (SPEC §5, codex rev-2 HIGH-5) — full-contract "is this
  rule already installed and live?" probe.

  Equality is the FULL live-rule contract:
    * `enabled == true`;
    * `source == system_default_source/0` (generator-installed only;
      an `:admin`-source rule is OPERATOR-OWNED, not ours to match);
    * workspace scope match (canonical-string);
    * normalized matcher (round-trip both sides via
      `Matcher.to_json/1` so tuple-AST matches map-form after a JSON
      snapshot round-trip);
    * receiver SET equality (canonical-string, order-insensitive).

  Returns:
    * `{:found, row}` — already installed + live (skip add).
    * `{:disabled, row}` — matches everything except `enabled == true`
      → operator drift (SPEC §7-4 — log + mark pending; do not
      re-enable).
    * `:not_found` — add this rule.
  """
  @spec existing_routing_rule_for(atom(), term(), [URI.t()], URI.t()) ::
          {:found, RuleStore.t()} | {:disabled, RuleStore.t()} | :not_found
  def existing_routing_rule_for(table, matcher_ast, receiver_uris, %URI{} = workspace_uri)
      when is_atom(table) and is_list(receiver_uris) do
    want_matcher = Ezagent.Routing.Matcher.to_json(matcher_ast)
    want_recv_set = MapSet.new(receiver_uris, &URI.to_string/1)
    want_ws = URI.to_string(workspace_uri)
    system_default = RuleStore.system_default_source()

    rows = RuleStore.list(table)

    case Enum.find(rows, fn r ->
           r.source == system_default and
             r.workspace_uri == want_ws and
             r.matcher_data == want_matcher and
             MapSet.new(r.receivers || [], &to_string/1) == want_recv_set
         end) do
      nil ->
        :not_found

      %{enabled: true} = row ->
        {:found, row}

      %{enabled: false} = row ->
        {:disabled, row}
    end
  end

  defp slot_uri_map(slot_results) do
    Map.new(slot_results, fn
      {slot_name, {:ok, _src, worker_uri}} -> {slot_name, worker_uri}
      {slot_name, {:already_converged, _src, worker_uri}} -> {slot_name, worker_uri}
      {slot_name, {:error, _}} -> {slot_name, nil}
    end)
    |> Map.reject(fn {_k, v} -> v == nil end)
  end

  # ─────────────────────────────────────────────────────────────────────
  # Step 5 — merge_working_copy  (SPEC §2 step 5, codex rev-2 HIGH-3 +
  # rev-3 HIGH-1 + rev-4 HIGH-2)
  # ─────────────────────────────────────────────────────────────────────

  defp merge_working_copy(
         %URI{} = session_uri,
         template_content,
         slot_results,
         %URI{} = workspace_uri,
         %URI{} = orchestrator_uri
       ) do
    prior = read_template_working_copy(session_uri)

    prior_slots_map =
      Enum.reduce(prior.agent_slots || [], %{}, fn
        {name, src, worker, gen}, acc -> Map.put(acc, to_string(name), {name, src, worker, gen})
        _, acc -> acc
      end)

    desired_slot_names =
      template_content
      |> Map.get(:agent_slots, [])
      |> normalize_agent_slots()
      |> Enum.map(fn {n, _t} -> n end)

    source_template_for =
      template_content
      |> Map.get(:agent_slots, [])
      |> normalize_agent_slots()
      |> Map.new()

    this_pass_slots_map =
      Enum.reduce(slot_results, %{}, fn
        {name, {:ok, src, worker}}, acc -> Map.put(acc, to_string(name), {name, src, worker, 0})
        {name, {:already_converged, src, worker}}, acc ->
          Map.put(acc, to_string(name), {name, src, worker, 0})
        _, acc -> acc
      end)

    merged_slots =
      Enum.map(desired_slot_names, fn name ->
        this_entry = Map.get(this_pass_slots_map, name)
        prior_entry = Map.get(prior_slots_map, name)

        cond do
          # codex rev-4 HIGH-2: re-validate this-pass entry's ownership
          # at MERGE time. A slot that converged earlier in THIS pass
          # could be concurrently re-parented before the merge runs.
          this_entry != nil and slot_still_owned?(this_entry, workspace_uri, orchestrator_uri) ->
            this_entry

          # No this-pass entry (or it just lost ownership); prior is
          # present + still owned (codex rev-3 HIGH-1 — includes
          # AgentLineage match, not just KindRegistry + workspace).
          prior_entry != nil and slot_still_owned?(prior_entry, workspace_uri, orchestrator_uri) ->
            prior_entry

          # Genuinely pending — write nil-worker tuple so the
          # orchestrator UI surfaces "this slot has no live worker".
          true ->
            source_uri = Map.get(source_template_for, name)
            {name, source_uri, nil, 0}
        end
      end)

    working_copy = %{
      agent_slots: merged_slots,
      routing_rules: normalize_routing_rules(Map.get(template_content, :routing_rules, [])),
      orchestrator_template_uri:
        Map.get(template_content, :orchestrator_template_uri) ||
          URI.parse("template://agent/default/cc-orchestrator"),
      default_workspace_uri: Map.get(template_content, :default_workspace_uri) || workspace_uri,
      description: Map.get(template_content, :description, "")
    }

    case Ezagent.Behavior.Chat.system_set_working_copy(session_uri, working_copy) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_working_copy_result, other}}
    end
  end

  defp slot_still_owned?({_name, _src, %URI{} = worker_uri, _gen}, ws_uri, orch_uri) do
    worker_already_owned_by_us?(worker_uri, orch_uri, ws_uri)
  end

  defp slot_still_owned?({_n, _s, nil, _g}, _ws, _orch), do: false
  defp slot_still_owned?(_, _, _), do: false

  defp read_template_working_copy(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        chat_slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(Ezagent.Behavior.Chat.state_slice(), %{})

        Ezagent.Behavior.Chat.template_working_copy(chat_slice)

      :error ->
        Ezagent.Behavior.Chat.default_template_working_copy()
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Step 6 — grant_scoped_caps_idempotent  (SPEC §2 step 6, codex rev-2
  # HIGH-1)
  # ─────────────────────────────────────────────────────────────────────

  defp grant_scoped_caps_idempotent(
         %URI{} = orchestrator_uri,
         %URI{} = session_uri,
         %URI{} = owner_uri
       ) do
    session_workspace =
      case Ezagent.WorkspaceRegistry.lookup(session_uri) do
        {:ok, ws} ->
          ws

        :error ->
          raise "session #{URI.to_string(session_uri)} has no workspace binding " <>
                  "— cannot derive workspace_uri for orchestrator scope caps"
      end

    desired = build_desired_caps(orchestrator_uri, session_uri, owner_uri, session_workspace)
    current = Ezagent.Identity.list_caps_for(orchestrator_uri)

    to_grant =
      Enum.reject(desired, fn want ->
        Enum.any?(current, &cap_equal_ignoring_metadata?(&1, want))
      end)

    target = URI.new!("#{URI.to_string(orchestrator_uri)}?action=identity.grant_cap")

    ctx = %{
      caller: owner_uri,
      caps: Ezagent.Entity.User.admin_caps(),
      reply: :ignore
    }

    results =
      Enum.map(to_grant, fn want ->
        cap = %{want | granted_at: DateTime.utc_now()}

        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :call,
          args: %{cap: cap},
          ctx: ctx
        })
      end)

    case Enum.reject(results, &match?({:ok, _}, &1)) do
      [] -> :ok
      [err | _] -> {:error, {:scoped_cap_grant_failed, err}}
    end
  end

  defp build_desired_caps(
         %URI{} = orchestrator_uri,
         %URI{} = session_uri,
         %URI{} = owner_uri,
         %URI{} = session_workspace
       ) do
    # Cap #1 + #2 — unconditional scope-bounded delegation.
    unconditional = [
      %Ezagent.Capability{
        kind: :session,
        behavior: :any,
        instance: {:within_session, session_uri},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: nil
      },
      %Ezagent.Capability{
        kind: :agent,
        behavior: :any,
        instance: {:spawned_by, orchestrator_uri},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: nil
      }
    ]

    # Caps #3/#4 — gated by owner-cap preflight (§1.4).
    template_caps = delegable_template_caps(owner_uri, session_workspace)

    unconditional ++ template_caps
  end

  @doc """
  PR-A helper (SPEC §5, codex rev-2 HIGH-1) — logical-equality
  predicate for capabilities, IGNORING `granted_at` (a per-dispatch
  timestamp).

  The IDENTITY of a cap is `{kind, behavior, instance, workspace_uri,
  granted_by}` — the authority being granted + WHO granted it. The
  WHEN is metadata; the same authority granted twice should be a
  no-op, NOT two distinct rows in the cap MapSet (which would burden
  the audit log + grow the User snapshot on every reconciler re-run).
  """
  @spec cap_equal_ignoring_metadata?(Ezagent.Capability.t(), Ezagent.Capability.t()) ::
          boolean()
  def cap_equal_ignoring_metadata?(%Ezagent.Capability{} = a, %Ezagent.Capability{} = b) do
    a.kind == b.kind and
      a.behavior == b.behavior and
      a.instance == b.instance and
      a.workspace_uri == b.workspace_uri and
      a.granted_by == b.granted_by
  end

  # ─────────────────────────────────────────────────────────────────────
  # Step 7 — register_orchestrator_mcp_context  (SPEC §2 step 7)
  # ─────────────────────────────────────────────────────────────────────

  defp register_orchestrator_mcp_context(
         %URI{} = orchestrator_uri,
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = owner_uri,
         %URI{} = parent_template_uri
       ) do
    Ezagent.Orchestrator.McpRegistry.register(orchestrator_uri,
      session_uri: session_uri,
      workspace_uri: workspace_uri,
      owner_uri: owner_uri,
      parent_template_uri: parent_template_uri
    )
  end

  # ─────────────────────────────────────────────────────────────────────
  # Outcome assembly  (SPEC §2 "outcome assembly")
  # ─────────────────────────────────────────────────────────────────────

  defp assemble_outcome(
         session_uri,
         orchestrator_uri,
         slot_results,
         routing_outcome,
         wc_outcome,
         caps_outcome,
         mcp_outcome
       ) do
    completed = [:session, :orchestrator]
    pending = []
    errors = []

    # Slots
    {completed, pending, errors, slot_pairs} =
      Enum.reduce(slot_results, {completed, pending, errors, []}, fn
        {slot, {:ok, _src, worker}}, {c, p, e, ok_slots} ->
          {[{:slot, slot} | c], p, e, [{slot, worker} | ok_slots]}

        {slot, {:already_converged, _src, worker}}, {c, p, e, ok_slots} ->
          {[{:slot, slot} | c], p, e, [{slot, worker} | ok_slots]}

        {slot, {:error, reason}}, {c, p, e, ok_slots} ->
          {c, [{:slot, slot} | p], [{{:slot, slot}, reason} | e], ok_slots}
      end)

    slot_pairs = Enum.reverse(slot_pairs)

    # Routing
    {completed, pending, errors, _routing_ids} =
      case routing_outcome do
        {:ok, ids} ->
          {[:routing | completed], pending, errors, ids}

        {:partial, route_pending, ids} ->
          {[:routing | completed], pending ++ Enum.map(route_pending, &elem(&1, 1)),
           errors ++ Enum.map(route_pending, fn {:rule, r} -> {:routing, r} end), ids}

        {:error, reason} ->
          {completed, [:routing | pending], [{:routing, reason} | errors], []}
      end

    # Working copy
    {completed, pending, errors} =
      case wc_outcome do
        :ok -> {[:working_copy | completed], pending, errors}
        {:error, reason} -> {completed, [:working_copy | pending], [{:working_copy, reason} | errors]}
      end

    # Caps
    {completed, pending, errors} =
      case caps_outcome do
        :ok -> {[:caps | completed], pending, errors}
        {:error, reason} -> {completed, [:caps | pending], [{:caps, reason} | errors]}
      end

    # MCP context
    {completed, pending, errors} =
      case mcp_outcome do
        :ok -> {[:mcp_context | completed], pending, errors}
        {:error, reason} -> {completed, [:mcp_context | pending], [{:mcp_context, reason} | errors]}
      end

    if pending == [] and errors == [] do
      {:ok,
       %{
         session_uri: session_uri,
         orchestrator_uri: orchestrator_uri,
         slots: slot_pairs
       }}
    else
      {:partial,
       %{
         session_uri: session_uri,
         orchestrator_uri: orchestrator_uri,
         completed: Enum.reverse(completed),
         pending: Enum.reverse(pending),
         errors: Enum.reverse(errors)
       }}
    end
  end

  defp partial_report(opts) do
    {:partial,
     %{
       session_uri: Keyword.get(opts, :session_uri),
       orchestrator_uri: Keyword.get(opts, :orchestrator_uri),
       completed: Keyword.get(opts, :completed, []),
       pending: Keyword.get(opts, :pending, []),
       errors: Keyword.get(opts, :errors, [])
     }}
  end

  # ─────────────────────────────────────────────────────────────────────
  # Preflights — KEPT verbatim (rounds 1-3 hardening, security-critical)
  # ─────────────────────────────────────────────────────────────────────

  defp preflight_slot_name_uniqueness(template_content) do
    slot_specs =
      template_content
      |> Map.get(:agent_slots, [])
      |> normalize_agent_slots()
      |> Enum.map(fn {slot_name, _agent_template_uri} -> {slot_name, 0} end)

    Ezagent.Orchestrator.SlotNames.preflight(slot_specs, "preflight")
  end

  defp preflight_workspace_isolation(
         %URI{} = session_template_uri,
         %URI{} = workspace_uri,
         template_content
       ) do
    template_ws = Ezagent.Capability.workspace_of(session_template_uri)

    with :ok <- same_workspace(template_ws, workspace_uri, :default_workspace_uri),
         :ok <- slots_in_workspace(template_content, template_ws) do
      :ok
    end
  end

  defp same_workspace(%URI{host: a}, %URI{host: b}, _which) when is_binary(a) and a == b,
    do: :ok

  defp same_workspace(_template_ws, _other_ws, which),
    do: {:error, {:cross_workspace_denied, which}}

  defp slots_in_workspace(template_content, %URI{} = template_ws) do
    slots = normalize_agent_slots(Map.get(template_content, :agent_slots, []))

    Enum.reduce_while(slots, :ok, fn {slot_name, %URI{} = agent_template_uri}, :ok ->
      case Ezagent.Capability.workspace_of(agent_template_uri) do
        %URI{host: ws} when is_binary(ws) and ws == template_ws.host ->
          {:cont, :ok}

        other ->
          {:halt,
           {:error,
            {:cross_workspace_denied, {:agent_slot, slot_name, slot_workspace_label(other)}}}}
      end
    end)
  end

  defp slot_workspace_label(%URI{} = uri), do: URI.to_string(uri)
  defp slot_workspace_label(other), do: other

  defp ensure_template_alive(%URI{} = template_uri) do
    case Ezagent.KindRegistry.lookup(template_uri) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case Ezagent.SpawnRegistry.spawn(template_uri) do
          {:ok, _} = ok -> ok
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = err -> err
        end
    end
  end

  defp owner_instantiate_preflight(%URI{} = session_template_uri, %URI{} = owner_uri) do
    owner_caps = Ezagent.Identity.list_caps_for(owner_uri)

    needed = %{
      kind: :session_template,
      behavior: Ezagent.Behavior.Template,
      instance: session_template_uri,
      workspace_uri: Ezagent.Capability.workspace_of(session_template_uri)
    }

    if Enum.any?(owner_caps, &Ezagent.Capability.matches?(&1, needed)) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp read_template_content(%URI{} = session_template_uri) do
    target = URI.parse("#{URI.to_string(session_template_uri)}?action=template.read")

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{
             caller: Ezagent.Entity.User.admin_uri(),
             caps: Ezagent.Entity.User.admin_caps(),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{content: content}} when is_map(content) -> {:ok, content}
      {:ok, %{content: nil}} -> {:error, :session_template_not_populated}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_template_read_result, other}}
    end
  end

  defp resolve_target_workspace(template_content) do
    case Map.get(template_content, :default_workspace_uri) ||
           Map.get(template_content, "default_workspace_uri") do
      nil ->
        Ezagent.WorkspaceRegistry.default_workspace_uri()

      %URI{scheme: "workspace", host: host} = uri when is_binary(host) ->
        validate_workspace_name(host, uri)

      uri_str when is_binary(uri_str) ->
        case URI.parse(uri_str) do
          %URI{scheme: "workspace", host: host} = uri when is_binary(host) ->
            validate_workspace_name(host, uri)

          _ ->
            {:error, {:invalid_default_workspace_uri, uri_str}}
        end

      other ->
        {:error, {:invalid_default_workspace_uri, other}}
    end
  end

  defp validate_workspace_name(host, %URI{} = uri) do
    if Regex.match?(~r/^[a-z][a-z0-9_-]*$/, host) do
      {:ok, uri}
    else
      {:error, {:invalid_workspace_name, host}}
    end
  end

  defp preflight_routing_rules(template_content) do
    rules = normalize_routing_rules(Map.get(template_content, :routing_rules, []))

    Enum.reduce_while(rules, :ok, fn {matcher_ast, _receivers}, :ok ->
      try do
        _ = Ezagent.Routing.Matcher.to_json(matcher_ast)
        {:cont, :ok}
      rescue
        _ -> {:halt, {:error, {:invalid_routing_matcher, matcher_ast}}}
      end
    end)
  end

  # session discriminator: the session URI's name segment.
  defp session_discriminator(%URI{} = session_uri) do
    case session_uri.path do
      "/" <> rest ->
        case String.split(rest, "/", parts: 2) do
          [_ws, name] when name != "" -> name
          _ -> session_uri.host || "session"
        end

      _ ->
        session_uri.host || "session"
    end
  end

  # Read an AgentTemplate's `flavor` from its `:template` slice via the
  # `template.read` dispatch. Returns `:no_flavor` when the read fails
  # or the content has no flavor — caller falls back to dispatch path.
  defp agent_template_flavor(%URI{} = agent_template_uri) do
    target = URI.parse("#{URI.to_string(agent_template_uri)}?action=template.read")

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{
             caller: Ezagent.Entity.User.admin_uri(),
             caps: Ezagent.Entity.User.admin_caps(),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{content: content}} when is_map(content) ->
        case Map.get(content, :flavor) || Map.get(content, "flavor") do
          flavor when is_binary(flavor) and flavor != "" -> {:ok, flavor}
          _ -> :no_flavor
        end

      _ ->
        :no_flavor
    end
  end

  defp normalize_agent_slots(slots) when is_list(slots) do
    Enum.map(slots, fn
      {slot_name, %URI{} = uri} -> {to_string(slot_name), uri}
      {slot_name, uri} when is_binary(uri) -> {to_string(slot_name), URI.parse(uri)}
      [slot_name, %URI{} = uri] -> {to_string(slot_name), uri}
      [slot_name, uri] when is_binary(uri) -> {to_string(slot_name), URI.parse(uri)}
    end)
  end

  defp normalize_agent_slots(_), do: []

  defp normalize_routing_rules(rules) when is_list(rules) do
    Enum.map(rules, fn
      {matcher_ast, receivers} when is_list(receivers) -> {matcher_ast, receivers}
      [matcher_ast, receivers] when is_list(receivers) -> {matcher_ast, receivers}
    end)
  end

  defp normalize_routing_rules(_), do: []

  # ─────────────────────────────────────────────────────────────────────
  # Routing insert txn — KEPT structurally (the per-pass batch atomicity
  # invariant survives the reconciler model — round-4 HIGH-1).
  # ─────────────────────────────────────────────────────────────────────

  defp insert_routing_rules_txn([], _table, _workspace_uri, _owner_uri), do: {:ok, []}

  defp insert_routing_rules_txn(rules, table, workspace_uri, owner_uri) do
    txn =
      EzagentCore.Repo.transaction(fn ->
        result =
          Enum.reduce_while(rules, [], fn {matcher_ast, receiver_uris}, ids ->
            case RuleStore.add(
                   table,
                   matcher_ast,
                   receiver_uris,
                   owner_uri,
                   workspace_uri: workspace_uri,
                   source: RuleStore.system_default_source()
                 ) do
              {:ok, %{id: id}} ->
                {:cont, [id | ids]}

              {:error, reason} ->
                EzagentCore.Repo.rollback({:routing_rule_failed, reason})
            end
          end)

        Enum.reverse(result)
      end)

    case txn do
      {:ok, ids} -> {:ok, ids}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:routing_install_raised, e}}
  catch
    kind, reason -> {:error, {:routing_install_raised, {kind, reason}}}
  end

  defp safe_load_registry(table) do
    RuleStore.load_into_registry(table)
    :ok
  rescue
    e -> {:error, {:registry_reload_failed, e}}
  catch
    kind, reason -> {:error, {:registry_reload_failed, {kind, reason}}}
  end

  defp try_safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # ─────────────────────────────────────────────────────────────────────
  # Owner-cap preflight for caps #3 and #4  (KEPT verbatim — round-1 §1.4)
  # ─────────────────────────────────────────────────────────────────────

  defp delegable_template_caps(%URI{} = owner_uri, %URI{} = session_workspace) do
    owner_caps = Ezagent.Identity.list_caps_for(owner_uri)
    workspace_name = session_workspace.host || "default"

    candidates = [
      {:session_template, URI.new!("template://session/#{workspace_name}/_preflight@_")},
      {:agent_template, URI.new!("template://agent/#{workspace_name}/_preflight")}
    ]

    candidates
    |> Enum.filter(fn {kind, representative_uri} ->
      needed = %{
        kind: kind,
        behavior: Ezagent.Behavior.Template,
        instance: representative_uri,
        workspace_uri: session_workspace
      }

      Enum.any?(owner_caps, &Ezagent.Capability.matches?(&1, needed))
    end)
    |> Enum.map(fn {kind, _representative_uri} ->
      %Ezagent.Capability{
        kind: kind,
        behavior: Ezagent.Behavior.Template,
        instance: {:within_workspace, session_workspace},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: nil
      }
    end)
  end
end
