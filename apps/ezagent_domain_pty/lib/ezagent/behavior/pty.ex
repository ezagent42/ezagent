defmodule Ezagent.ActionSet.Pty do
  @moduledoc """
  Pty Behavior — `:write` action for an Agent Kind backed by a local
  `Ezagent.Domain.Pty.Server`.

  ## PR #146 (SPEC v2 §5.7) — agent-direct dispatch

  The previous synthetic `pty-input://default` singleton is dissolved.
  PTY input now dispatches to the target agent's own URI:

      entity://agent/team-alpha/cc_<name>?action=pty.write   args: %{bytes: "..."}

  The Agent Kind hosts this Behavior; `ctx.self_uri` (injected by
  `Ezagent.Kind.Runtime`) is the agent URI used to locate the
  PtyServer via the `Ezagent.Domain.Pty.lookup/1` facade
  (`EzagentDomainPty.Registry` is the underlying :via name source).

  ## Domain.Pty PR-A / PR-B (2026-05-21 SPEC v1)

  PtyServer (now `Ezagent.Domain.Pty.Server`) moved out of the cc
  plugin into the Tier-2 `ezagent_domain_pty` app in PR-A. PR-B
  (this PR) moves this Behavior module into the same app — the
  module atom name `Ezagent.ActionSet.Pty` is unchanged, so all
  existing DB cap grants (`caps_json` references the string
  `"Elixir.Ezagent.ActionSet.Pty"`) continue to resolve.

  The Behavior MODULE lives in `ezagent_domain_pty`; the
  REGISTRATION (binding Agent Kind → :write → this module) happens
  in `EzagentDomainInstanceMessage.Application.start/2` where the
  `Ezagent.Entity.Agent` Kind is defined. `ezagent_domain_session`
  gains `:ezagent_domain_pty` as an in-umbrella dep so this
  module is loadable at registration time.

  ## Critical invariant (IMPLEMENTATION_ROADMAP §1.3 #1)

  Every operator-typed byte goes through `Ezagent.Router.dispatch`
  → CapBAC step 5.5 → audit telemetry → PtyServer write. The xterm.js
  hook never touches the PtyServer directly or pushes raw PubSub.

  ## Cap shape

  - `kind: :agent`
  - `behavior: Ezagent.ActionSet.Pty`
  - `instance: entity://agent/<flavor>_<name>` (per-agent) or `:any`

  Admin's triple-`:any` passes. Grant per-agent for non-admin users.

  ## Migration to §2.2 declarative contract (Phase 2.5 — 2026-05-28)

  Per SPEC `2026-05-28-router-behavior-kind-architecture.md` §6.2,
  migrated from `@behaviour Ezagent.ActionSet` + `invoke/4` to
  `use Ezagent.ActionSet` + `action/3` + `handle_write/2`.

  Semantically equivalent — the PtyServer write call stays inline
  in the handler body because its return value (`:ok` vs error)
  gates both the slice mutation and the action result. The effect
  grammar discards `:effect` return values; expressing the write as
  an effect would require `:effect_returning` which is fine for
  pure side effects but cannot also abort the action on failure.
  Inline keeps the failure-propagation contract identical to the
  legacy contract clause (matches the pattern documented in
  `Ezagent.ActionSet.Session`'s moduledoc — "result-dependent in-handler
  dispatches stay as direct calls in the handler body").

  ## Lifecycle migration (Phase B, SPEC 2026-05-29 §2.3 — the
  ## NO-TRANSIENTS case, like example A `CurlAgent`)

  Converted from `use Ezagent.ActionSet` to `use Ezagent.Lifecycle`
  (the two-container `%{state, transients}` developer API).

  ### Why NO transients

  Despite the name, this Behavior holds NO process-bound resource in
  its slice. The PtyServer port/process is owned by the
  `ezagent_domain_pty` app's own supervised `Ezagent.Domain.Pty.Server`
  and is resolved fresh on every write via `Ezagent.Domain.Pty.lookup/1`
  (the `EzagentDomainPty.Registry` `:via` source). The Behavior's slice
  is therefore PURE durable counters:

  - **STATE (persistent):** `write_calls`, `total_bytes` — cumulative
    write accounting that legitimately survives a restart (the §1.3 #1
    audit invariant counts every operator-typed byte). Built by `create/1`.
  - **TRANSIENT:** none. The PtyServer handle is NOT held here, so
    `activate/2` is the macro-injected no-op default (omitted) — there
    is nothing process-bound to rebuild. A snapshot rehydrates the
    counters directly; no dead reference can be carried across a restart
    because no reference lives in the slice.

  This is the simple example-A shape (`CurlAgent`): `init_slice/1` →
  `create/1` builds the durable `state`, `handle_write/2` is byte-identical
  except `ctx[:read]` reads now resolve against the Lifecycle `:state`
  container (the runtime + `get_slice/2` normalization handle the
  two-container split transparently).

  The auto-derived `state_slice/0` (last module segment `Pty` → `:pty`)
  equals the historical snapshot key, so NO `state_slice:` override is
  needed (SPEC §5 step 2 / §7 OQ-7).

  Naming (§11 NP-1/NP-2/NP-3 audit): `Ezagent.ActionSet.Pty` — a domain
  module (`apps/ezagent_domain_pty`) naming its own domain concept
  (`Pty`), single `:write` action whose intent the name tracks exactly.
  NO violation; kept as-is (a rename would touch the `:pty` snapshot
  slice key + every DB cap grant referencing `"Elixir.Ezagent.ActionSet.Pty"`
  for no clarity gain).
  """

  use Ezagent.Lifecycle

  action(:write,
    args: %{bytes: :string},
    returns: %{bytes_written: :integer},
    caps: [:write],
    modes: [:call, :cast],
    description: "Write raw bytes to the agent's PTY input stream"
  )

  action(:restart,
    args: %{},
    returns: %{restarted: :boolean},
    caps: [:restart],
    modes: [:call],
    description: "Clear a respawn-breaker halt and respawn the agent's PTY subprocess"
  )

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Pty is registered on the Agent Kind — kind axis is `:agent`. The
  # macro-derived default would be `:any`; we override to preserve
  # the `:agent` axis the CapabilityRegistry needs to match the
  # existing grants.
  def required_caps do
    %{
      write: Ezagent.Capability.cap(:agent, __MODULE__, :write),

      # `:restart` is gated by the agent's MANAGE cap, not a PTY cap —
      # the same idiom `Ezagent.ActionSet.ConfigGovernance` uses for its CR
      # actions (lead decision OQ-4: "the agent's MANAGE cap, no separate
      # cap"). `Kind.Runtime` overwrites the needed-cap's ACTION with the
      # dispatched action but honours the declared BEHAVIOR, so a held
      # `cap(:agent, Manage, :any, <this agent>)` matches `:restart`.
      #
      # Recovering a dead agent is a management act on the instance, not
      # terminal typing. The creator already holds exactly that cap from
      # `CreatorGrant.manage_cap/4` (#533 §3.3 — "any management action on
      # THIS instance"), so Allen's 2026-07-13 decision ("the agent's
      # creator has authority to recover it") needs no new grant and no
      # backfill. Pinned by the three authz tests in `pty_test.exs`.
      restart: Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Manage, :any)
    }
  end

  # The auto-derived slice key for `Ezagent.ActionSet.Pty` is the
  # underscored last segment `Pty` → `:pty`, which is EXACTLY the
  # pre-Lifecycle `state_slice/0`. The snapshot-compat key is preserved
  # with no explicit override needed (SPEC §3 / §7 OQ-7).

  # `init_slice/1` → `create/1` (SPEC §3 mapping). Build the initial
  # PERSISTENT `state` once, on first-ever existence. No transients
  # (the PtyServer handle is resolved per-write, never held), so
  # `activate/2` is the macro-injected no-op default.
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{write_calls: 0, total_bytes: 0}}

  def handle_write(%{bytes: bytes}, ctx) when is_binary(bytes) do
    case Map.get(ctx, :self_uri) do
      %URI{} = agent_uri ->
        case Ezagent.Domain.Pty.lookup(agent_uri) do
          {:ok, pid} ->
            case Ezagent.Domain.Pty.Server.write_input(pid, bytes) do
              :ok ->
                # `state` may be `%{}` on first write — the host Agent
                # Kind doesn't list `Behavior.Pty` in `behaviors/0`
                # (PR #146: cc plugin can't be a chat-domain dep, so the
                # Behavior is added via BehaviorRegistry at boot, not
                # statically declared). Initialize lazily from the
                # `create/1` base so re-writes accumulate normally.
                # (Under Lifecycle `create/1` returns the durable `state`
                # map directly; we pull its defaults for the lazy seed.)
                {:ok, base} = create(%{})

                prev_write_calls = ctx[:read].(:write_calls, base.write_calls)
                prev_total_bytes = ctx[:read].(:total_bytes, base.total_bytes)

                new_write_calls = prev_write_calls + 1
                new_total_bytes = prev_total_bytes + byte_size(bytes)

                {:ok, %{bytes_written: byte_size(bytes)},
                 [
                   {:set, :write_calls, new_write_calls},
                   {:set, :total_bytes, new_total_bytes}
                 ]}

              {:error, _reason} = err ->
                err

              other ->
                {:error, {:pty_write_failed, other}}
            end

          :error ->
            {:error, :no_pty_server}
        end

      _ ->
        {:error, {:invalid_ctx, :self_uri_missing}}
    end
  end

  def handle_write(_args, _ctx),
    do: {:error, {:invalid_args, :bytes_required}}

  @doc """
  Clear a respawn-breaker halt and respawn the agent's PTY subprocess.

  Gated by the MANAGE authority (see `required_caps/0`) — recovering a dead
  agent is a management act on the instance, not terminal typing. The creator's
  existing `cap(:agent, Manage, :any, <this agent>)` therefore carries it.
  """
  def handle_restart(_args, ctx) do
    case Map.get(ctx, :self_uri) do
      %URI{} = agent_uri ->
        case Ezagent.Domain.Pty.restart(agent_uri) do
          :ok -> {:ok, %{restarted: true}, []}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :no_self_uri}
    end
  end

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): per-entity Behavior
  # — the entity (user / agent) owns its own state for this Behavior.
  def data_owner(%URI{} = entity_uri), do: Ezagent.URI.instance(entity_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
