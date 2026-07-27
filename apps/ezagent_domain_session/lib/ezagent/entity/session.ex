defmodule Ezagent.Entity.Session do
  @moduledoc """
  Session Kind — the "room" in Phase 2's chat routing model.

  A Session is the entity that holds a set of member URIs and routes
  outbound chat messages to them. Per Decision #61 + P2-D2 K-path:
  Session handles `:send / :join / :leave` actions; the member-side
  `:receive` action runs on the recipient Kind (User / Agent).

  Phase 2 spawns exactly one default instance — `session://default/system/main` —
  at `EzagentDomainInstanceMessage.Application.start/2`. Multi-Session support is
  intentionally out of scope (Phase 3+).

  ## Persistence: {:snapshot, :on_change} — session membership survives restart

  See git history for the rationale (Allen V1 acceptance 2026-05-22) —
  the slice is now snapshotted on every change so membership +
  template_working_copy survive an unclean crash.
  """

  @behaviour Ezagent.Kind
  @behaviour Ezagent.ActionSet.Publisher

  # Compile-time env capture (release-safe; Mix is not loaded in releases).
  # Used by the orchestrator-readiness gate's test-mode bypass. (codex Q1.)

  @impl Ezagent.Kind
  def type_name, do: :session

  @impl Ezagent.Kind
  # P5-1b (socialware substrate collapse) — `behaviors/0` is now the UNION
  # of the chat + socialware behavior sets. The two former Session Kinds
  # (the chat Session + the standalone socialware-session Kind, now deleted)
  # collapsed into this ONE parameterized Kind; Templates select the
  # per-instance ACTIVE subset
  # via P1's `:kind_base` mechanism (`chat_behaviors/0` / `socialware_behaviors/0`
  # are the sets threaded at spawn). The declared list here is the SUPERSET;
  # the load-bearing P1 per-instance denial (`instance_set_gate`, runtime E9)
  # is what keeps a chat instance from invoking `turn.*`/`surface.*` even
  # though those Behaviors are declared on the Kind.
  #
  # ExternalMirror PR-EM-0 (SPEC §8.1) — `Publisher.SessionImpl` owns
  # the `:publisher` slice + serves the 3 publisher actions; declared
  # alongside Session so every Session instance can boot the publisher slice.
  #
  # ExternalMirror PR-EM-3 (SPEC §4.1) — `Behavior.ExternalMirror`
  # owns the `:external_mirror` slice + the bind / unbind /
  # list_bindings actions; declared here so `init_slice/1`
  # rehydrates the binding list from the projection table on
  # Session boot AND `post_init/2` schedules the worker
  # reconciliation handle_continue per SPEC §3.1.
  #
  # Turn / Surface (SPEC §3.1) — the socialware turn-state-machine +
  # surface-render Behaviors. Declared in the union; ACTIVE only on a
  # socialware-subset instance (a chat instance's `:kind_base` excludes them).
  def behaviors,
    do: [
      Ezagent.ActionSet.Session,
      Ezagent.ActionSet.Publisher.SessionImpl,
      Ezagent.ActionSet.ExternalMirror,
      Ezagent.ActionSet.Turn,
      Ezagent.ActionSet.Surface,
      Ezagent.ActionSet.SupervisorApproval
    ]

  @doc """
  The chat per-instance behavior subset (the `:kind_base` set threaded at a
  chat session spawn). Selects `{Session, Publisher, ExternalMirror}` out of
  the declared union — Turn/Surface are EXCLUDED, so `effective_set/2` denies
  `turn.*`/`surface.*` on a chat instance (P1 per-instance denial, SPEC §3.1).
  """
  @spec chat_behaviors() :: [module()]
  def chat_behaviors,
    do: [
      Ezagent.ActionSet.Session,
      Ezagent.ActionSet.Publisher.SessionImpl,
      Ezagent.ActionSet.ExternalMirror
    ]

  @doc """
  The socialware per-instance behavior subset (the `:kind_base` set threaded at
  a socialware/advisor session spawn). Selects `{Session, Turn, Surface,
  Publisher}` out of the declared union — `ExternalMirror` is EXCLUDED. This is
  the set the former standalone socialware-session Kind declared. Closed
  under `Turn → Surface` (required-sibling closure, `BehaviorSet.@required_reads`).
  """
  @spec socialware_behaviors() :: [module()]
  def socialware_behaviors,
    do: [
      Ezagent.ActionSet.Session,
      Ezagent.ActionSet.Turn,
      Ezagent.ActionSet.Surface,
      Ezagent.ActionSet.SupervisorApproval,
      Ezagent.ActionSet.Publisher.SessionImpl
    ]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  # P5-0b (socialware substrate collapse) — every Session instance MUST carry
  # an explicit (non-nil) `:kind_base` behavior set. The spawn paths thread
  # `:behaviors` (init_set stores a non-nil set); a nil capture fails loud in
  # `BehaviorSet.effective_set/2`. Scoped to the session Kind(s) so legacy
  # static Kinds keep their absent-`:behaviors` → declared compat path.
  @impl Ezagent.Kind
  def requires_explicit_behavior_set?, do: true

  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainInstanceMessage.SessionSupervisor

  @doc """
  URI of the default Session instance spawned at boot.

  SPEC v3 §3.6 — sessions are 3-segment: `session://<template>/<workspace>/<name>`.
  """
  @spec default_uri() :: URI.t()
  # PR #335 workspace rename (default → system) + Allen 2026-05-26
  # follow-up: this hardcoded literal was the writer behind the
  # ExternalMirrorWorker restart loop observed today. Every LV
  # bind flow / mix task that called default_uri/0 wrote the OLD
  # workspace name into the DB, leaving orphan binding rows the
  # boot reconciler couldn't resolve.
  def default_uri, do: Ezagent.URI.session(:system, :default, :main)

  # ─────────────────────────────────────────────────────────────────────
  # Ezagent.ActionSet.Publisher implementation (ExternalMirror PR-EM-0)
  #
  # The four callbacks below satisfy the `@behaviour Ezagent.ActionSet.Publisher`
  # contract declared at the top of this module. They route every
  # publisher action through `Ezagent.Invocation.dispatch/1` against the
  # Session's URI so caps are gated at step 5.5 + workspace isolation
  # at step 5.6 — same posture as any other Session action.
  #
  # SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  # §2.1 + §8.1. The actual ring + cursor + subscriber bookkeeping
  # lives in `Ezagent.ActionSet.Publisher.SessionImpl` (the Behavior
  # added to `behaviors/0`).
  # ─────────────────────────────────────────────────────────────────────

  @doc """
  Retention policy for the V1 Session publisher: 100 events
  (count-based; per OQ-EM-A resolution — option (a), Allen 2026-05-24).
  Override the slice-level `:retention` field via the
  `publisher_retention:` spawn arg if a per-session value is needed.
  """
  @impl Ezagent.ActionSet.Publisher
  def history_retention, do: 100

  @doc """
  Subscribe `subscriber_pid` to this Session's structured slice-change
  stream starting from `cursor` (`:latest`, `:earliest`, or an integer).

  ## Caller MUST supply their own ctx

  The `@behaviour Ezagent.ActionSet.Publisher` contract is 3-ary
  (per SPEC §2.1). The 3-ary form raises with a clear pointer to
  the 4-ary `subscribe_from/4` because the V1 codebase has no
  ambient-caps mechanism: every dispatch requires explicit
  `ctx.caller + ctx.caps` per CapBAC step 5.5, and a public 3-ary
  function with a default admin-caps fallback would let any in-VM
  caller bypass the Publisher cap (codex round-1 CRITICAL,
  2026-05-25).

  Use `subscribe_from/4` and pass an explicit `ctx` map containing
  `:caller` (a `%URI{}`) and `:caps` (a MapSet of `%Capability{}`
  the caller actually holds). Production Worker callers (PR-EM-2)
  pass their own ctx; tests pass admin caps explicitly.
  """
  @impl Ezagent.ActionSet.Publisher
  def subscribe_from(%URI{} = _publisher_uri, subscriber_pid, _cursor)
      when is_pid(subscriber_pid) do
    raise_no_ambient_caps!(:subscribe_from, 4)
  end

  @doc """
  Snapshot the Session's current publisher cursor + state without
  subscribing. See `subscribe_from/3` for the no-ambient-caps
  rationale — use `snapshot/2` with explicit ctx.
  """
  @impl Ezagent.ActionSet.Publisher
  def snapshot(%URI{} = _publisher_uri) do
    raise_no_ambient_caps!(:snapshot, 2)
  end

  @doc """
  Read events in the `(from, to]` cursor window from the Session's
  retained publisher ring. See `subscribe_from/3` for the
  no-ambient-caps rationale — use `history/4` with explicit ctx.
  """
  @impl Ezagent.ActionSet.Publisher
  def history(%URI{} = _publisher_uri, _from, _to) do
    raise_no_ambient_caps!(:history, 4)
  end

  @doc """
  4-ary `subscribe_from` that dispatches with the caller-supplied ctx.

  `ctx` MUST contain:

  - `:caller` — a `%URI{}` identifying the caller (used for CapBAC
    step 5.5 + workspace isolation step 5.6 + audit trail)
  - `:caps` — a `MapSet.t(%Ezagent.Capability{})` of caps the caller
    actually holds; step 5.5 verifies one matches the
    publisher-subscribe cap shape on this Session.

  Returns `{:ok, current_cursor}` on success;
  `{:error, :unauthorized}` if no held cap matches;
  `{:error, :cursor_out_of_window}` if `cursor` predates the oldest
  retained event; other `{:error, _}` shapes per the standard
  dispatch envelope.
  """
  @spec subscribe_from(URI.t(), pid(), Ezagent.ActionSet.Publisher.cursor(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def subscribe_from(%URI{} = publisher_uri, subscriber_pid, cursor, ctx)
      when is_pid(subscriber_pid) and is_map(ctx) do
    publisher_uri
    |> dispatch_publisher_action(
      :subscribe_from,
      %{subscriber_pid: subscriber_pid, cursor: cursor},
      ctx
    )
    |> unwrap_cursor()
  end

  @doc "2-ary `snapshot` with explicit caller ctx — see `subscribe_from/4`."
  @spec snapshot(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  def snapshot(%URI{} = publisher_uri, ctx) when is_map(ctx) do
    dispatch_publisher_action(publisher_uri, :snapshot, %{}, ctx)
  end

  @doc "4-ary `history` with explicit caller ctx — see `subscribe_from/4`."
  @spec history(
          URI.t(),
          Ezagent.ActionSet.Publisher.cursor(),
          Ezagent.ActionSet.Publisher.cursor(),
          map()
        ) ::
          {:ok, [Ezagent.Publisher.Event.t()]} | {:error, term()}
  def history(%URI{} = publisher_uri, from, to, ctx) when is_map(ctx) do
    publisher_uri
    |> dispatch_publisher_action(:history, %{from: from, to: to}, ctx)
    |> unwrap_events()
  end

  # Build + dispatch a publisher action against the publisher URI
  # using the caller-supplied `ctx`. The ctx MUST carry `:caller` +
  # `:caps`; if it doesn't, CapBAC step 5.5 will deny with
  # `{:error, :unauthorized}` (the let-it-crash posture — no default
  # caps, no implicit admin elevation).
  defp dispatch_publisher_action(%URI{} = publisher_uri, action, args, ctx) do
    target = Ezagent.URI.new!("#{URI.to_string(publisher_uri)}?action=publisher.#{action}")

    # Normalise the reply field: callers that didn't supply it get
    # `:ignore` (we still return the result via the synchronous dispatch
    # tuple — the reply field is only consumed by :cast mode + outbound
    # transports).
    normalised_ctx = Map.put_new(ctx, :reply, :ignore)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: normalised_ctx,
      origin: :trusted_internal
    })
  end

  defp unwrap_cursor({:ok, %{cursor: cursor}}), do: {:ok, cursor}
  defp unwrap_cursor({:error, _} = err), do: err

  defp unwrap_events({:ok, %{events: events}}), do: {:ok, events}
  defp unwrap_events({:error, _} = err), do: err

  defp raise_no_ambient_caps!(action, arity) do
    raise ArgumentError,
          "Ezagent.Entity.Session.#{action}/#{arity - 1} (the @behaviour " <>
            "Ezagent.ActionSet.Publisher 3-ary contract callback) requires an " <>
            "explicit caller ctx — use Ezagent.Entity.Session.#{action}/#{arity} " <>
            "with `ctx: %{caller: %URI{...}, caps: MapSet.new([...])}` instead. " <>
            "The V1 codebase has no ambient-caps mechanism; every dispatch " <>
            "must declare its caller + caps so CapBAC step 5.5 can gate " <>
            "non-Worker access (codex round-1 CRITICAL, 2026-05-25)."
  end

  @doc """
  PR-OWN-2 (caps-data-ownership SPEC #306 §7) — return the URI of the
  entity that "owns" this session (the user/agent that created it).

  Looks up the live Session Kind's `:chat` slice via
  `Ezagent.Kind.read/3` (`spawn: :never` — live-only). Returns:
  - `{:ok, %URI{}}` — the owner URI recorded at session creation
  - `{:ok, nil}` — session exists but has no recorded owner
    (system session, or pre-PR-OWN-2 snapshot without `:owner_uri`)
  - `{:error, reason}` — session not live (`:not_found`) or call failed

  Used by `Behavior.Session.data_owner/1` which converts the result
  into `%URI{} | :no_owner` for the cap-grant authorization path.
  """
  @spec owner(URI.t() | String.t()) :: {:ok, URI.t() | nil} | {:error, term()}
  def owner(uri) do
    # `read/3` normalizes the two-container `%{state, transients}` slice to
    # its `:state` view, so `:owner_uri` matches directly. `spawn: :never`
    # keeps this a live-only probe; its `{:error, :not_live}` is translated
    # back to the `{:error, :not_found}` this function has always returned
    # for a non-live session (asserted by session_owner_test).
    case Ezagent.Kind.read(uri, :session, spawn: :never) do
      {:ok, %{owner_uri: owner_uri}} -> {:ok, owner_uri}
      {:ok, nil} -> {:ok, nil}
      {:ok, _} -> {:ok, nil}
      {:error, :not_live} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  @doc false
  def orchestrator_spawn_template_opts(%URI{} = owner_uri, %URI{} = orch_template_uri) do
    [
      caller: owner_uri,
      caps: Ezagent.Identity.list_caps_for(owner_uri),
      source_template_uri: orch_template_uri
    ]
  end

  @doc false
  def list_caps_for_materialization(%URI{} = actor_uri),
    do: Ezagent.Identity.list_caps_for(actor_uri)

  defdelegate ensure_orchestrator(session_uri, owner_uri, workspace_uri),
    to: Ezagent.Entity.Session.Orchestrator

  defdelegate orchestrator_uri(session_uri), to: Ezagent.Entity.Session.Orchestrator
  defdelegate orchestrator_instance_name(session_uri), to: Ezagent.Entity.Session.Orchestrator

  defdelegate planned_orchestrator_uri(session_uri, workspace_uri),
    to: Ezagent.Entity.Session.Orchestrator

  defdelegate worker_already_owned_by_us?(candidate_uri, session_uri, owner_uri),
    to: Ezagent.Entity.Session.Orchestrator

  defdelegate read_template_working_copy(template_uri), to: Ezagent.Entity.Session.Orchestrator
  defdelegate session_member_uris(session_uri), to: Ezagent.Entity.Session.Orchestrator

  defdelegate member_uris_from_snapshot_state(state), to: Ezagent.Entity.Session.Orchestrator

  defdelegate session_legends(session_uri), to: Ezagent.Entity.Session.Orchestrator

  defdelegate grant_orchestrator_scoped_caps(orchestrator_uri, session_uri, owner_uri),
    to: Ezagent.Entity.Session.Orchestrator

  defdelegate revoke_orchestrator_scoped_caps(
                orchestrator_uri,
                session_uri,
                owner_uri,
                workspace_uri
              ),
              to: Ezagent.Entity.Session.Orchestrator

  defdelegate cap_equal_ignoring_metadata?(left, right),
    to: Ezagent.Entity.Session.Orchestrator

  defdelegate register_orchestrator_mcp_context(
                orchestrator_uri,
                session_uri,
                workspace_uri,
                owner_uri,
                parent_template_uri,
                binding_epoch
              ),
              to: Ezagent.Entity.Session.Orchestrator

  @doc """
  Ensure the template Kind at `template_uri` is alive, spawning it (via
  `SpawnRegistry`) if the `KindRegistry` lookup misses. Returns
  `{:ok, pid}` | `{:error, reason}`.

  Kept in this façade because `Session` is the sanctioned spawn-registry
  chokepoint for template materialization.
  """
  @spec ensure_template_alive(URI.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_template_alive(%URI{} = template_uri) do
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

  defdelegate read_template_content(session_template_uri), to: Ezagent.Entity.Session.Orchestrator
end
