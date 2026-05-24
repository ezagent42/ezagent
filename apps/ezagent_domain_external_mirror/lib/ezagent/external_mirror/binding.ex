defmodule Ezagent.ExternalMirror.Binding do
  @moduledoc """
  `Ezagent.ExternalMirror.Binding` — behaviour every external-mirror
  binding module declares.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §2.3 / §6.

  A Binding is the **stateful per-target transport layer** — one
  binding INSTANCE = one supervised process = one external target.
  The Worker Kind (`Ezagent.Entity.ExternalMirrorWorker`) is the
  GenServer skeleton that holds the publisher subscription + cursor
  + retry state; the Binding module implements the transport
  callbacks (`init/1`, `publish/2`, optional `terminate/2`).

  Per-binding GenServer + PerBindingSupervisor isolation (SPEC §5.3 +
  §6.3) means a binding's transport failures never affect siblings.

  ## PR-EM-1 stub vs PR-EM-2 full set

  PR-EM-1 shipped only `adapter_module/0` so plugin declarations
  could be Grill-5-checked at compile time. PR-EM-2 EXPANDS the
  contract:

  | Callback | Since | Purpose |
  |---|---|---|
  | `adapter_module/0` | PR-EM-1 | Grill-5 bidirectional declaration |
  | `init/1` | **PR-EM-2** | open transport (HTTP client / WS / RPC stream); called from the Worker Kind's `handle_continue/2` (NOT from `init_slice/1` — r4 HIGH-1 deadlock fix) |
  | `publish/2` | **PR-EM-2** | send a translated payload to the external target; the only callback where external bytes flow |
  | `terminate/2` | **PR-EM-2 (optional)** | release transport resources on graceful unbind |

  ## Bidirectional declaration (Grill 5)

  Each side names the OTHER so a misconfiguration (typo, copy-paste
  error, two-adapters-one-binding accident) fails the build, not
  the runtime. `Ezagent.Plugin.boot/1`'s `assert_adapter_decl!`
  runs five checks per `(adapter, binding)` pair from
  `Ezagent.Plugin.adapters/0`:

  1. `adapter` implements `@behaviour Ezagent.ExternalMirror.Adapter`.
  2. `binding` implements `@behaviour Ezagent.ExternalMirror.Binding`.
  3. `adapter.binding_module() == binding`.
  4. `binding.adapter_module() == adapter`.
  5. `adapter != binding` (a single module implementing both
     behaviours is rejected — would dissolve the boundary).

  Per SPEC §5.1 + §9 (PR-EM-1 acceptance).
  """

  @typedoc """
  Opaque per-binding runtime state. The Domain stores it on the
  Worker Kind's `:external_mirror_worker` slice's `binding_state`
  field; the Binding module reads/writes it via `publish/2`.

  Typical contents: HTTP client pid, cached tenant tokens,
  rate-limit reset timestamps, connection handle.
  """
  @type state :: term()

  @typedoc """
  Opaque per-target identifier. Carried verbatim from `:bind` action
  args to `init/1`. The Binding's adapter parses it (Feishu: a Lark
  chat_id string; game adapter: a room_id integer; …).
  """
  @type target_id :: term()

  @typedoc """
  Result of `publish/2`.

  - `{:ok, new_state}` — success. State may carry rate-limit reset
    times, last-publish cursors, connection handles.
  - `{:error, reason, new_state}` — RECOVERABLE failure (4xx/5xx,
    network blip). The Worker Kind logs + telemetry'd but does NOT
    crash; the binding is structurally healthy. State carries
    forward (e.g. retry counter, backoff deadline).

  Per SPEC §2.3: RAISE on UNrecoverable invariant violations (the
  BEAM let-it-crash path) — the Worker Kind's PerBindingSupervisor
  restarts per `:transient`-bound budget. The recoverable shape
  exists so transient HTTP errors don't churn the supervisor
  restart counter.
  """
  @type publish_result ::
          {:ok, new_state :: state()}
          | {:error, reason :: term(), new_state :: state()}

  # ----- Required callbacks --------------------------------------------------

  @doc """
  The Adapter module paired with this Binding (Grill-5 bidirectional
  declaration; the compiler asserts
  `binding.adapter_module() == adapter` AND
  `adapter.binding_module() == binding`).
  """
  @callback adapter_module() :: module()

  @doc """
  Initialize per-binding transport state. Called ONCE from the
  Worker Kind's `handle_continue(:subscribe_and_init, ...)` (NOT
  from `init_slice/1` — SPEC §6.1 + §8.3 r4 HIGH-1 deadlock fix).

  `target_id` is opaque to the framework (string, integer, map —
  whatever the adapter parses). `adapter` is the matching
  `Ezagent.ExternalMirror.Adapter` module (provided so the binding
  can call back into the adapter for e.g. authentication helpers).
  `options` carries binding-time metadata from the `:bind` action
  args (caller-supplied configuration, `bound_by`, `bound_at`).

  Returns the binding's initial runtime state — held by the Worker
  Kind in `:external_mirror_worker.binding_state` and threaded
  through subsequent `publish/2` + `terminate/2` calls.

  ## Failure semantics

  - `{:ok, state}` — transport ready; Worker enters `subscription_state: :active`.
  - `{:error, reason}` — the Worker raises (SPEC §6.2). The
    PerBindingSupervisor restarts per `:permanent` + `max_restarts: 3,
    max_seconds: 30` budget; if init keeps failing the
    PerBindingSupervisor itself crashes and stays down (operator
    sees telemetry; unbinds to remove).

  Per `feedback_let_it_crash_no_workarounds` (Allen 2026-05-05) —
  NO `:warning`+degrade paths; failure surfaces structurally
  via the supervisor crash budget.
  """
  @callback init({target_id :: target_id(), adapter :: module(), options :: map()}) ::
              {:ok, state :: state()} | {:error, reason :: term()}

  @doc """
  Publish a translated payload to the external target. Called from
  inside the Worker Kind's `:invoke(:publish, ...)` (SPEC §6.1).

  By the time the Binding sees this call, the adapter has already
  translated the Publisher event into `payload` via
  `event_to_payload/1`. The binding does the actual transport call
  (HTTP/WS/RPC/whatever) and returns updated state.

  Per **P14** (every external write happens inside a Kind's invoke)
  this is the ONLY place where external bytes flow.

  See `t:publish_result/0` for the return shape contract.
  """
  @callback publish(payload :: term(), state :: state()) :: publish_result()

  # ----- Optional callbacks -------------------------------------------------

  @doc """
  Cleanup on graceful unbind. Called BEFORE the Worker Kind's
  process exits (SPEC §3 + §6.2). The Binding releases held
  resources (close WS pid, send goodbye message, close HTTP
  pool).

  Default behaviour (when not exported): no-op.

  Note: this is NOT called on a crash — the Worker exits brutally
  and its process state is reaped by the PerBindingSupervisor.
  The graceful path runs only on `:unbind` via
  `DynamicSupervisor.terminate_child/2` propagating `:shutdown`.
  """
  @callback terminate(reason :: term(), state :: state()) :: :ok

  @optional_callbacks [terminate: 2]
end
