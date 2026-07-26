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
      (the same protocol verb `Ezagent.Kind.Server` already handles);
    * `send_envelope/2` — resolves internally and sends a raw message;
    * `whereis/1` — liveness only (`:ok | :not_found`), no pid;
    * `alive?/1` — liveness as a plain boolean;
    * `terminate_child/2` — resolves internally and asks the CALLER-NAMED
      `DynamicSupervisor` to terminate the child (the supervisor name is
      public knowledge; the pid stays in the seam);
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

  NOTE (A1a): unlike `Ezagent.Invocation.dispatch/1` this seam performs NO
  lazy spawn, no outbox, and no policy hook — it is the resolution+delivery
  primitive those higher layers will sit on after A1b.
  """
  @spec dispatch(URI.t() | String.t(), atom(), map(), map()) ::
          {:ok, term()} | :ok | {:error, :no_such_actor} | {:error, term()}
  def dispatch(uri, action, args, ctx)
      when is_atom(action) and is_map(args) and is_map(ctx) do
    case pid_for(uri) do
      {:ok, pid} ->
        inv = invocation(uri, action, args, ctx)

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
  """
  @spec terminate_child(key(), DynamicSupervisor.supervisor()) :: :ok | :not_found
  def terminate_child(key, supervisor) do
    case pid_for(key) do
      {:ok, pid} ->
        case DynamicSupervisor.terminate_child(supervisor, pid) do
          :ok -> :ok
          {:error, :not_found} -> :not_found
        end

      :not_found ->
        :not_found
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

  # Build the standard dispatch envelope. Mirrors the Router's private
  # Cmd→Invocation encoding (`?action=_.<action>` target annotation, mode
  # derivation, caps/reply defaults) — duplicated HERE, not called through,
  # because the seam must deliver to its OWN resolved pid while the Router
  # resolves independently; A1b consolidates the two paths onto this seam.
  defp invocation(uri, action, args, ctx) do
    legacy_ctx =
      ctx
      |> Map.put_new(:caps, MapSet.new())
      |> Map.put_new(:reply, :ignore)
      |> normalize_caps()

    %Invocation{
      target: uri |> to_uri() |> annotate_target(action),
      mode: derive_mode(legacy_ctx),
      args: args,
      ctx: legacy_ctx
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
