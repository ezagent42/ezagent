defmodule Ezagent.ExternalMirror.Adapter do
  @moduledoc """
  `Ezagent.ExternalMirror.Adapter` — behaviour every external-mirror
  adapter module declares.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §2.2 / §5.

  An Adapter is a **stateless, pure-function module** that knows how
  to translate `Ezagent.Publisher.Event` values into wire-format
  payloads for ONE external system (Feishu, Slack, a game protocol,
  …). It does NOT call external APIs from `event_to_payload/1` —
  the matching `Ezagent.ExternalMirror.Binding` GenServer owns the
  transport.

  ## PR-EM-1 stub vs PR-EM-2 full set

  PR-EM-1 shipped a minimal four-callback shape so plugin
  declarations could be Grill-5-checked at compile time. PR-EM-2
  EXPANDS the contract to the full SPEC §2.2 set:

  | Callback | Since | Purpose |
  |---|---|---|
  | `adapter_id/0` | PR-EM-1 | registry key |
  | `display_name/0` | PR-EM-1 | operator-facing name |
  | `description/0` | PR-EM-1 | operator-facing one-line description |
  | `binding_module/0` | PR-EM-1 | Grill-5 bidirectional declaration |
  | `cap_subject/0` | **PR-EM-2** | per-adapter authorization cap shape (Cap 2, §4.2) |
  | `target_ownership_check/2` | **PR-EM-2** | bind-time external-system membership check (Cap 3, §4.2) |
  | `target_ownership_check_timeout/0` | **PR-EM-2 (optional)** | adapter override of the 5s default |
  | `event_to_payload/1` | **PR-EM-2** | the core publisher-event → wire-payload translation |

  Existing PR-EM-1 plugins MUST be updated to implement the new
  required callbacks before they can boot. The PR-EM-1 test mock
  (`apps/ezagent_domain_external_mirror/test/support/test_adapters.ex`)
  ships with the PR-EM-2 callbacks added; future plugins
  (Feishu — PR-EM-6) implement the full set from day one.

  ## Why `event_to_payload/1` is pure

  The translation function runs INSIDE the Worker Kind's
  `:publish` invoke (SPEC §6.1) — that is on the per-binding GenServer's
  scheduler quantum. Any I/O there would block the Worker for the
  duration of the call, defeating the per-binding crash boundary
  (one slow Lark API call would stall its own Worker but not its
  siblings — but a synchronous external call from `event_to_payload`
  would also defeat the let-it-crash posture by letting transient
  failures linger in retry loops inside the function). The
  Binding's `publish/2` is where the external bytes actually flow.

  ## `target_ownership_check/2` is the ONE allowed I/O callback

  This is the EXCEPTION to the "Adapter is pure" rule: the bind-time
  membership check (Cap 3 in SPEC §4.2) genuinely requires asking
  the external system "is `caller` a member of `target_id`?". The
  Domain runs this callback inside a `Task.Supervisor.async_nolink/3`
  with a bounded timeout (default 5s, override via
  `target_ownership_check_timeout/0`) so the calling GenServer is
  never blocked. PR-EM-3 wires this into the bind facade
  (per SPEC §8.2's r6 two-step facade pattern); PR-EM-2 only
  declares the callback shape.

  PR-EM-FINAL invariant test (g) enforces that
  `target_ownership_check/2` MUST NOT call `Ezagent.Invocation.dispatch/1`
  (directly or transitively) — re-entering ezagent dispatch from
  inside this callback creates a dispatch-during-dispatch deadlock
  because `:bind` is itself a dispatched action.

  ## P3-1 adapter KIND axis — `:push` vs `:pull`

  Every adapter has a **kind** (`adapter_kind/0`), resolved via
  `kind_of/1`:

  - `:push` (the DEFAULT) — the original external-mirror shape. A push
    adapter has a paired `Ezagent.ExternalMirror.Binding` GenServer that
    owns the per-binding external transport; on `:bind` the Domain spawns
    a Worker that calls `binding_module.init/1` then `publish/2` for each
    event. Required callbacks: `binding_module/0`, `cap_subject/0`,
    `target_ownership_check/2`, `event_to_payload/1` (plus the PR-EM-1
    id/name/description trio).

  - `:pull` — a feed served on demand by its CALLER's Phoenix channel
    (the socialware customer feed, built in P3-2). A pull adapter has NO
    per-binding external transport: no `binding_module/0`, no
    `target_ownership_check/2`, no `event_to_payload/1`, and registering
    one spawns NO Worker. Instead it implements `render/2`, which returns
    the json-render map for a session on demand. Required callbacks:
    `render/2` + `cap_subject/0` (plus the id/name/description trio).

  `adapter_kind/0` is an OPTIONAL callback with a back-compat default of
  `:push` (resolved through `kind_of/1`), so EXISTING adapters (Feishu
  mirror, the test adapters) remain valid WITHOUT declaring it. The
  registry's required-callback enforcement
  (`Ezagent.ExternalMirror.AdapterRegistry`) branches on `kind_of/1`, and
  the binding/Worker-startup path (`Ezagent.ExternalMirror.AdapterInstall`)
  is gated on `kind_of(adapter) == :push`.
  """

  @typedoc "Stable string id for the AdapterRegistry."
  @type adapter_id :: String.t()

  @typedoc """
  Adapter kind axis (P3-1). `:push` (the default) has a paired Binding +
  Worker; `:pull` is served on demand by its caller's Phoenix channel and
  has no per-binding transport.
  """
  @type adapter_kind :: :push | :pull

  @typedoc """
  Per-adapter cap subject shape returned from `cap_subject/0`. The
  `behavior_module` is a marker Behavior (typically cap-only) that
  authorizes a user to bind THIS adapter on a session (Cap 2 in
  SPEC §4.2). Convention: `Behavior.ExternalAdapter.<adapter_id>.Allow`.
  """
  @type cap_subject :: %{
          behavior_module: module(),
          description: String.t()
        }

  @typedoc """
  Result of `event_to_payload/1`. `:skip` tells the Binding to drop
  the event without publishing (e.g. an adapter that only cares
  about `:chat` slice changes returns `:skip` for `:members` slice
  changes — SPEC §2.2).
  """
  @type payload_result :: {:publish, payload :: term()} | :skip

  @typedoc """
  Result of `target_ownership_check/2`. `:not_a_member` is the
  canonical denial atom; adapters MAY return other reasons that the
  Domain surfaces verbatim to the caller (per P18 — no silent
  drops). `:target_check_timeout` is reserved for the Domain to
  return when the Task-supervised call exceeds
  `target_ownership_check_timeout/0`; adapters MUST NOT return it.
  """
  @type target_check_result ::
          :ok
          | {:error, :not_a_member | :target_check_timeout | term()}

  # ----- Required callbacks (both kinds) -------------------------------------

  @doc "Stable string key — the AdapterRegistry's lookup key."
  @callback adapter_id() :: adapter_id()

  @doc "Operator-facing name (shown in admin LV picker)."
  @callback display_name() :: String.t()

  @doc "Operator-facing description (1-2 sentences)."
  @callback description() :: String.t()

  # ----- Push-required callbacks ---------------------------------------------
  #
  # P3-1: `binding_module/0`, `target_ownership_check/2`, and
  # `event_to_payload/1` are REQUIRED only for `:push` adapters. They are
  # listed in `@optional_callbacks` so the compiler does not flag a `:pull`
  # adapter (which legitimately omits them) — the per-kind requirement is
  # enforced at runtime by `Ezagent.ExternalMirror.AdapterRegistry`'s
  # `assert_required_callbacks!/1` (the registry has always been the
  # authoritative gate; see that module's moduledoc).

  @doc """
  The Binding module paired with this Adapter (Grill-5 bidirectional
  declaration; the compiler asserts
  `adapter.binding_module() == binding` AND
  `binding.adapter_module() == adapter`).

  REQUIRED for `:push` adapters; a `:pull` adapter has no per-binding
  transport and omits it (P3-1).
  """
  @callback binding_module() :: module()

  @doc """
  The per-adapter cap subject (Behavior module + description) that
  authorizes a user to bind to THIS adapter (Cap 2 in SPEC §4.2).

  The returned `behavior_module` is registered with
  `Ezagent.CapabilityRegistry` at plugin boot — that gives it a
  stable cap shape (`{kind: :session, behavior: <that module>,
  instance: session_uri, workspace_uri: ws}`) that PR-EM-3's bind
  facade checks before dispatching `:bind` to the Session.

  Convention: name the Behavior module
  `Ezagent.Behavior.ExternalAdapter.<AdapterId>.Allow` so admin LV
  cap listings group naturally.
  """
  @callback cap_subject() :: cap_subject()

  @doc """
  Check at BIND TIME whether `caller` has access to `target_id` on
  the external system (Cap 3 in SPEC §4.2).

  Examples:
  - Feishu adapter: "is `caller`'s linked feishu_open_id a member of
    Lark chat `target_id`?" — Lark API call.
  - Slack adapter: channel membership query.
  - Game adapter: "does `caller`'s game account own room `target_id`?".

  Returns `:ok` on grant; `{:error, :not_a_member}` on the canonical
  denial; `{:error, other_reason}` on adapter-specific denial — the
  Domain surfaces the reason verbatim to the caller per P18.

  ## Contract (SPEC §2.2 r4)

  - This callback is the ONE adapter callback ALLOWED to make
    external API calls (Lark/Slack/etc); `event_to_payload/1` MUST
    be pure.
  - This callback MUST NOT call `Ezagent.Invocation.dispatch/1`
    directly or transitively. Re-entering ezagent dispatch from
    here creates a dispatch-during-dispatch deadlock because
    `:bind` is itself a dispatched action. PR-EM-FINAL grep gate
    invariant test (g) enforces.
  - PR-EM-3 wires the bind facade to run this callback inside a
    `Task.Supervisor.async_nolink/3` with a bounded timeout
    (default 5s, override via `target_ownership_check_timeout/0`).
    PR-EM-2 only declares the callback shape.
  """
  @callback target_ownership_check(caller :: URI.t(), target_id :: term()) ::
              target_check_result()

  @doc """
  Translate a Publisher event into adapter-specific payload (SPEC §2.2).

  Pure function — no I/O. Runs inside the Worker Kind's
  `:invoke(:publish, ...)` (per §6.1) — the matching Binding then
  consumes the returned `{:publish, payload}` and performs the
  transport via `publish/2`.

  Returning `:skip` tells the Binding to drop this event without
  publishing (e.g. an adapter that only cares about `:chat` slice
  changes returns `:skip` for `:members` slice changes — common for
  partial-projection adapters).
  """
  @callback event_to_payload(event :: Ezagent.Publisher.Event.t()) :: payload_result()

  # ----- Optional callbacks --------------------------------------------------

  @doc """
  Maximum time (ms) the Domain's bind facade waits for
  `target_ownership_check/2` to return before timing out
  (default 5000ms). Override only if the external system genuinely
  requires a longer membership check.

  PR-EM-3 reads this via `function_exported?/3`; when not exported
  the facade uses the 5000ms default.
  """
  @callback target_ownership_check_timeout() :: pos_integer()

  @doc """
  The adapter's KIND (P3-1). `:push` (default) or `:pull`. Optional with a
  back-compat default of `:push` resolved via `kind_of/1` — EXISTING
  adapters need not declare it.
  """
  @callback adapter_kind() :: adapter_kind()

  @doc """
  Render the on-demand json view of `session_uri` for a `:pull` adapter
  (P3-1). REQUIRED for `:pull` adapters (enforced by
  `Ezagent.ExternalMirror.AdapterRegistry`), unused by `:push` adapters.

  `ctx` carries caller/request context (shape defined by the pull
  transport in P3-2). Returns the json-render map served by the caller's
  Phoenix channel.
  """
  @callback render(session_uri :: URI.t(), ctx :: map()) :: map()

  # `@optional_callbacks` here means "the COMPILER won't warn if absent".
  # Push-required callbacks (`binding_module/0`, `target_ownership_check/2`,
  # `event_to_payload/1`) live here so a `:pull` adapter can omit them
  # warning-free; their per-kind requirement is enforced at runtime by
  # `Ezagent.ExternalMirror.AdapterRegistry.assert_required_callbacks!/1`.
  @optional_callbacks [
    target_ownership_check_timeout: 0,
    adapter_kind: 0,
    render: 2,
    binding_module: 0,
    target_ownership_check: 2,
    event_to_payload: 1
  ]

  @doc """
  Resolve an adapter module's KIND with the back-compat default.

  Returns `module.adapter_kind()` when the module exports
  `adapter_kind/0`, else `:push` — so adapters predating the P3-1 kind
  axis (Feishu mirror, test adapters) resolve to `:push` without editing.
  """
  @spec kind_of(module()) :: adapter_kind()
  def kind_of(adapter_module) when is_atom(adapter_module) do
    # `Code.ensure_loaded?/1` first: `function_exported?/3` returns false
    # for a not-yet-loaded module (which would mis-default a genuine `:pull`
    # adapter to `:push`). Same guard as `Gates.adapter_allow_action/1`.
    if Code.ensure_loaded?(adapter_module) and
         function_exported?(adapter_module, :adapter_kind, 0) do
      adapter_module.adapter_kind()
    else
      :push
    end
  end

  @doc """
  Invoke a `:pull` adapter's `render/2`. Thin helper so callers (the P3-2
  pull transport) have one chokepoint; raises with a clear message if the
  module is not a `:pull` adapter exporting `render/2`.
  """
  @spec render(module(), URI.t(), map()) :: map()
  def render(adapter_module, %URI{} = session_uri, ctx)
      when is_atom(adapter_module) and is_map(ctx) do
    unless function_exported?(adapter_module, :render, 2) do
      raise ArgumentError,
            "#{inspect(adapter_module)} does not export render/2 — only :pull " <>
              "adapters implement render/2 (P3-1). kind_of/1 == #{inspect(kind_of(adapter_module))}."
    end

    adapter_module.render(session_uri, ctx)
  end
end
