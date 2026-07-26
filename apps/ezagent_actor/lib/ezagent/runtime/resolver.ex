defmodule Ezagent.Runtime.Resolver do
  @moduledoc """
  V5 pid-closure, A1a — the single pid-acquisition SEAM (built ADDITIVE in
  A1a; A1b wires the PTY sidecar pilot onto it).

  North-star: "a pid is confined to one resolver". Every pid fetch in the
  system converges on `pid_for/1` here; every caller outside the seam holds
  only URIs / resolver keys, never pids. A1a builds the facade only —
  `Ezagent.KindRegistry` and the 6 per-plugin sidecar registries stay
  authoritative; no Kind and no sidecar is migrated (A1b), and no gate
  enforces the seam (A2).

  ## The key space

    * a **Kind URI** (`%URI{}` or binary) resolves through the EXISTING
      `Ezagent.KindRegistry` (string keys, unchanged — `KindRegistry.list_all/0`
      and `AutoDerive` assume string keys, so sidecar tuple keys are NEVER
      put into it);
    * a **sidecar key** `{parent_uri, plugin, role}` resolves through the new
      unified `Ezagent.Runtime.SidecarRegistry` (plugin-qualified tuple keys;
      children `:via`-self-register, so entries die with their child).

  ## The public face never returns a pid

    * `call/3` — resolves internally, `GenServer.call/3`s the target and
      returns the REPLY (never the pid);
    * `cast/2` — resolves internally and `GenServer.cast/2`s the target;
    * `dispatch/4` — resolves internally and delivers the standard
      `{:ezagent_dispatch, %Ezagent.Invocation{}}` envelope to the target
      (the same protocol verb `Ezagent.Kind.Server` already handles). The
      envelope's `origin` is CALLER-OWNED (`ctx.origin`, V5 A1b): the seam
      preserves it and REJECTS a missing/invalid one rather than stamping
      `:trusted_internal` itself;
    * `send_envelope/2` — resolves internally and sends a raw message;
    * `whereis/1` — liveness only (`:ok | :not_found`), no pid;
    * `alive?/1` — liveness as a plain boolean;
    * `terminate_child/2` — resolves internally and asks the CALLER-NAMED
      `DynamicSupervisor` to terminate the child (the supervisor name is
      public knowledge; the pid stays in the seam). `terminate_child/3` with
      `sync: true` additionally BLOCKS until the child is DOWN and the
      registry key no longer resolves to the terminated pid (V5 A1b-rest
      chunk 3 — teardown→recreate paths like SessionManager `stop/1`);
    * `list_keys/1` — key-only enumeration of one plugin's sidecar
      entries (KEYS, never pids) — the `list_agents/0`-style replacement.

  `pid_for/1` is public-for-the-seam (INTERNAL): it is the sole place a pid
  is fetched. Callers outside the seam must use the public face above — a
  sidecar facade should NEVER need to call `pid_for/1` itself (A1b codex
  review: the pilot leaked one through `find_by_agent_uri/1`; the
  `call/cast/alive?/terminate_child/list_keys` face is what closes that).
  """

  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Runtime.SidecarRegistry

  @typedoc """
  A resolver key: a Kind URI, or a plugin-qualified sidecar tuple.
  """
  @type key :: URI.t() | String.t() | {URI.t() | String.t(), atom(), atom()}

  @doc """
  INTERNAL — the SOLE place a pid is fetched from a resolver key.

  Returns `{:ok, pid}` or `:not_found`. A sidecar key on an UNSTARTED
  `SidecarRegistry` (the A1a default — nothing wires it yet) is `:not_found`,
  never a crash.
  """
  @spec pid_for(key()) :: {:ok, pid()} | :not_found
  def pid_for({parent_uri, plugin, role})
      when is_atom(plugin) and is_atom(role) do
    if SidecarRegistry.started?() do
      case SidecarRegistry.lookup({parent_uri, plugin, role}) do
        {:ok, pid} -> {:ok, pid}
        :error -> :not_found
      end
    else
      :not_found
    end
  end

  def pid_for(%URI{} = uri), do: kind_pid(uri)
  def pid_for(uri) when is_binary(uri), do: kind_pid(uri)

  # Provenance the resolver accepts from its CALLER (V5 A1b codex blocker A).
  # The seam NEVER invents an origin: stamping `:trusted_internal` here would
  # let any in-BEAM caller launder external-origin traffic as internal. These
  # are exactly `Ezagent.DispatchOrigin`'s two positive values — kept as local
  # literals because the actor app must not reach up into staying-core (the
  # §4.2 REVERSE boundary gate).
  @accepted_origins [:authenticated_external, :trusted_internal]

  @doc """
  PUBLIC face — resolve `uri` internally and dispatch `action` to it, never
  returning the pid.

  Builds the standard `%Ezagent.Invocation{}` envelope (same
  `?action=_.<action>` target encoding + `ctx` normalization as the Router's
  Cmd→Invocation step) and delivers it DIRECTLY to the resolved pid as
  `{:ezagent_dispatch, invocation}` — `GenServer.call/3` for `:call` /
  `:call_stream` modes, `GenServer.cast/2` for `:cast` (mode derived from
  `ctx` exactly as the Router derives it). Returns `{:error, :no_such_actor}`
  when the target is not registered.

  PROVENANCE IS CALLER-OWNED (V5 A1b codex blocker A): the caller must supply
  the dispatch origin as `ctx.origin` — one of `:authenticated_external` or
  `:trusted_internal`. The resolver PRESERVES that stamp on the envelope and
  NEVER invents one: a missing origin is rejected with
  `{:error, :missing_origin}`, an unknown one with
  `{:error, {:invalid_origin, origin}}` (no default, no laundering). The
  `:origin` key is consumed here (stamped on the envelope, not passed through
  in `ctx`).

  NOTE (A1a): unlike `Ezagent.Invocation.dispatch/1` this seam performs NO
  lazy spawn, no outbox, and no policy hook — it is the resolution+delivery
  primitive those higher layers will sit on after A1b.
  """
  @spec dispatch(URI.t() | String.t(), atom(), map(), map()) ::
          {:ok, term()}
          | :ok
          | {:error, :no_such_actor}
          | {:error, :missing_origin}
          | {:error, {:invalid_origin, term()}}
          | {:error, term()}
  def dispatch(uri, action, args, ctx)
      when is_atom(action) and is_map(args) and is_map(ctx) do
    case fetch_origin(ctx) do
      {:ok, origin, ctx} ->
        case pid_for(uri) do
          {:ok, pid} ->
            inv = invocation(uri, action, args, ctx, origin)

            case inv.mode do
              :cast ->
                GenServer.cast(pid, {:ezagent_dispatch, inv})
                :ok

              _call ->
                GenServer.call(pid, {:ezagent_dispatch, inv}, call_timeout(ctx))
            end

          :not_found ->
            {:error, :no_such_actor}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  PUBLIC face — resolve `key` internally and send `msg` to it, never
  returning the pid. `:ok` when delivered, `:not_found` otherwise.
  """
  @spec send_envelope(key(), term()) :: :ok | :not_found
  def send_envelope(key, msg) do
    case pid_for(key) do
      {:ok, pid} ->
        Kernel.send(pid, msg)
        :ok

      :not_found ->
        :not_found
    end
  end

  @doc """
  PUBLIC face — liveness of `key` WITHOUT exposing the pid:
  `:ok` (registered) or `:not_found`.
  """
  @spec whereis(key()) :: :ok | :not_found
  def whereis(key) do
    case pid_for(key) do
      {:ok, _pid} -> :ok
      :not_found -> :not_found
    end
  end

  @doc """
  PUBLIC face — resolve `key` internally and `GenServer.call/3` the target,
  returning the REPLY (never the pid).

    * `{:ok, reply}` — the target's reply, whatever its shape;
    * `{:error, :no_such_actor}` — nothing registered under `key`;
    * `{:error, reason}` — the call itself failed (target died or was busy
      past `timeout` mid-call): the exit reason, caught so a caller facing
      a respawn-backing-off server gets a clean `{:error, _}` instead of an
      escaping exit.
  """
  @spec call(key(), term(), timeout()) ::
          {:ok, term()} | {:error, :no_such_actor} | {:error, term()}
  def call(key, msg, timeout \\ 5_000) do
    case pid_for(key) do
      {:ok, pid} ->
        try do
          {:ok, GenServer.call(pid, msg, timeout)}
        catch
          :exit, reason -> {:error, reason}
        end

      :not_found ->
        {:error, :no_such_actor}
    end
  end

  @doc """
  PUBLIC face — resolve `key` internally and `GenServer.cast/2` the target,
  never returning the pid. `:ok` when delivered, `:not_found` otherwise.
  """
  @spec cast(key(), term()) :: :ok | :not_found
  def cast(key, msg) do
    case pid_for(key) do
      {:ok, pid} ->
        GenServer.cast(pid, msg)
        :ok

      :not_found ->
        :not_found
    end
  end

  @doc """
  PUBLIC face — liveness of `key` as a plain boolean (the codex-named form
  of `whereis/1`, which is kept for its `:ok | :not_found` callers).
  """
  @spec alive?(key()) :: boolean()
  def alive?(key), do: whereis(key) == :ok

  @doc """
  PUBLIC face — resolve `key` internally and ask the CALLER-NAMED
  `DynamicSupervisor` to terminate the child.

  The caller names its own supervisor (public knowledge — a sidecar app
  knows the supervisor its workers live under); the PID stays inside the
  seam. This is the pid-free replacement for sidecars calling `pid_for/1`
  to feed `DynamicSupervisor.terminate_child/2` themselves. `:ok` when the
  child was terminated (or the supervisor no longer had it), `:not_found`
  when nothing is registered under `key`.

  ## `sync: true` — the synchronous variant (V5 A1b-rest chunk 3)

  With `sync: true` the call BLOCKS until the child is provably gone: the
  seam `Process.monitor`s the resolved pid, issues the supervisor
  `terminate_child`, waits for the `{:DOWN, ...}` (bounded, 5s), then waits
  out the `SidecarRegistry`'s ASYNCHRONOUS DOWN-cleanup so the `:unique` key
  no longer resolves to the terminated pid before returning. A
  fire-and-forget teardown lets an immediate recreate observe the dying
  `:via` registration and reuse a STALE pid (the Registry frees its entry on
  its own monitor, not synchronously with `terminate_child`); the sync
  variant exists for teardown→recreate paths (e.g. SessionManager `stop/1`,
  whose rollback→recreate must never race) that need the key provably free
  on return. The pid stays in the seam either way.
  """
  @spec terminate_child(key(), DynamicSupervisor.supervisor(), keyword()) :: :ok | :not_found
  def terminate_child(key, supervisor, opts \\ []) do
    case pid_for(key) do
      {:ok, pid} ->
        if Keyword.get(opts, :sync, false) do
          terminate_child_sync(key, supervisor, pid)
        else
          terminate_supervisor_child(supervisor, pid)
        end

      :not_found ->
        :not_found
    end
  end

  # The plain (fire-and-forget) variant: the Registry's async DOWN-cleanup
  # frees the key a beat later — callers that `alive?`-probe right after must
  # poll (the chunk-2 eventually-consistent gotcha).
  defp terminate_supervisor_child(supervisor, pid) do
    case DynamicSupervisor.terminate_child(supervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :not_found
    end
  end

  # Bounded wait for the child's :DOWN (matches the 5s bound the old
  # SessionManager `stop/1` used for the same guarantee).
  @sync_terminate_down_timeout 5_000

  # Bounded extra wait for the SidecarRegistry's async DOWN-cleanup once the
  # child is confirmed dead (50 × 10ms — cleanup is prompt; this only absorbs
  # the registry's scheduling lag).
  @sync_terminate_key_free_attempts 50

  defp terminate_child_sync(key, supervisor, pid) do
    ref = Process.monitor(pid)

    case DynamicSupervisor.terminate_child(supervisor, pid) do
      :ok ->
        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} ->
            await_key_free(key, pid, @sync_terminate_key_free_attempts)
        after
          @sync_terminate_down_timeout ->
            Process.demonitor(ref, [:flush])
        end

        :ok

      {:error, :not_found} ->
        Process.demonitor(ref, [:flush])
        :not_found
    end
  end

  # The Registry frees the :via entry on its own :DOWN monitor — prompt but
  # ASYNC w.r.t. the caller's. Poll (bounded) until the seam no longer
  # resolves the key to the TERMINATED pid; a DIFFERENT pid means a
  # replacement already owns the key (fine — our terminate still landed).
  defp await_key_free(_key, _pid, 0), do: :ok

  defp await_key_free(key, pid, attempts) do
    case pid_for(key) do
      {:ok, ^pid} ->
        Process.sleep(10)
        await_key_free(key, pid, attempts - 1)

      _ ->
        :ok
    end
  end

  @doc """
  PUBLIC face — key-only enumeration: every resolver key one PLUGIN has
  self-registered in the unified `SidecarRegistry`, as normalized
  `{parent_uri_string, plugin, role}` tuples. NEVER a pid — this is the
  seam's replacement for `list_agents/0`-style pid enumeration (the pid
  stays inside `SidecarRegistry.entries_for_plugin/1`, seam-internal).

  The returned keys are directly usable with `call/3`, `cast/2`,
  `alive?/1` and `terminate_child/2` for per-entry follow-up queries.
  """
  @spec list_keys(atom()) :: [SidecarRegistry.key()]
  def list_keys(plugin) when is_atom(plugin) do
    plugin
    |> SidecarRegistry.entries_for_plugin()
    |> Enum.map(fn {parent_uri, role, _pid} -> {parent_uri, plugin, role} end)
  end

  # ── Internals ──────────────────────────────────────────────────────────────

  defp kind_pid(uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} -> {:ok, pid}
      :error -> :not_found
    end
  end

  # Extract and validate the CALLER-OWNED dispatch origin (V5 A1b codex
  # blocker A). The caller's stamp is returned alongside the ctx with the
  # `:origin` key consumed (provenance lives on the envelope, not in ctx). A
  # missing origin REJECTS — the seam never defaults to `:trusted_internal`.
  defp fetch_origin(ctx) do
    case Map.pop(ctx, :origin) do
      {nil, _ctx} ->
        {:error, :missing_origin}

      {origin, ctx} when origin in @accepted_origins ->
        {:ok, origin, ctx}

      {origin, _ctx} ->
        {:error, {:invalid_origin, origin}}
    end
  end

  # Build the standard dispatch envelope. Mirrors the Router's private
  # Cmd→Invocation encoding (`?action=_.<action>` target annotation, mode
  # derivation, caps/reply defaults) — duplicated HERE, not called through,
  # because the seam must deliver to its OWN resolved pid while the Router
  # resolves independently; A1b consolidates the two paths onto this seam.
  #
  # `origin:` is the CALLER-OWNED stamp `dispatch/4` already validated
  # (dispatch-provenance gate): the seam is a delivery primitive that
  # PRESERVES provenance, never manufactures it — an origin-less envelope
  # would be rejected by `handle_dispatch`'s `validate_origin/2`, and this
  # file is registered as a dynamic-origin site with the DispatchOrigin
  # source gate.
  defp invocation(uri, action, args, ctx, origin) do
    legacy_ctx =
      ctx
      |> Map.put_new(:caps, MapSet.new())
      |> Map.put_new(:reply, :ignore)
      |> normalize_caps()

    %Invocation{
      target: uri |> to_uri() |> annotate_target(action),
      mode: derive_mode(legacy_ctx),
      args: args,
      ctx: legacy_ctx,
      origin: origin
    }
  end

  defp to_uri(%URI{} = uri), do: uri
  defp to_uri(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)

  # The legacy dispatch path expects `target` to embed the action as the
  # query string (`_.<action>` — the `_` behavior-name sentinel, exactly as
  # the Router synthesises it for `%Cmd{}` dispatches).
  defp annotate_target(%URI{query: nil} = uri, action),
    do: %{uri | query: "action=_.#{action}"}

  defp annotate_target(%URI{query: query} = uri, action) when is_binary(query) do
    if String.contains?(query, "action=") do
      uri
    else
      %{uri | query: query <> "&action=_.#{action}"}
    end
  end

  defp derive_mode(%{mode: mode}) when mode in [:call, :cast, :call_stream], do: mode
  defp derive_mode(%{reply: :ignore}), do: :cast
  defp derive_mode(%{reply: {kind, _}}) when is_atom(kind), do: :call
  defp derive_mode(_), do: :call

  defp normalize_caps(%{caps: nil} = ctx), do: %{ctx | caps: MapSet.new()}
  defp normalize_caps(%{caps: %MapSet{}} = ctx), do: ctx
  defp normalize_caps(%{caps: caps} = ctx) when is_list(caps), do: %{ctx | caps: MapSet.new(caps)}
  defp normalize_caps(ctx), do: Map.put(ctx, :caps, MapSet.new())

  defp call_timeout(ctx), do: Map.get(ctx, :deadline_ms) || 5_000
end
