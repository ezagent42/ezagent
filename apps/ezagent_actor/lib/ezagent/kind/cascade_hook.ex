defmodule Ezagent.Kind.CascadeHook do
  @moduledoc """
  The cascade hook at the single slice-mutation emit chokepoint (membership-cap
  unification Phase B.3, spec §10 / K3).

  `Ezagent.Kind.Server.commit_and_notify/3` calls `maybe_enqueue/1` right after
  `Ezagent.SliceChange.emit/1`, on the SAME post-commit gate. For an allowlisted
  `{scheme, slice_key}` slice change (initially `{"entity", :identity}` — a cap
  grant/revoke mutates an entity's `:identity` slice), it enqueues a
  self-targeted, fire-and-forget `:cascade_notify_managers` dispatch on the
  post-commit `Ezagent.Kind.DeferredDispatch` turn — EXACTLY like
  `deferred_dispatch`, NOT a per-URI subscriber (per-URI subscription doesn't
  scale, carried codex Blocker 3).

  Why a Cmd rather than calling a resolver directly: the resolve + content-free
  notify lives in the DOMAIN (`Ezagent.Identity.Cascade`), which core must not
  reference (layer purity). Routing a plain-atom action Cmd to the changed
  entity's own Kind keeps core layer-pure (the action is data — no compile edge)
  and runs the resolver in the domain on the target's Kind.

  It stays OFF the mutating dispatch's critical path: `DeferredDispatch.enqueue`
  only sends `self()` a message, so the actual dispatch runs on a LATER mailbox
  turn — a slow/failing cascade can never roll back the mutation. `maybe_enqueue/1`
  MUST be called synchronously from inside the `Kind.Server` process so `self()`
  is that server.
  """

  # Allowlisted `{scheme, slice_key}` pairs that trigger the cascade. A cap
  # grant/revoke mutates the `:identity` slice (`Ezagent.ActionSet.Identity`'s
  # `state_slice`), so the caps-change signal is `{"entity", :identity}` — spec
  # §10 names the `:caps` CONTAINER; the emitted slice_key is `:identity`.
  @cascade_allowlist [{"entity", :identity}]
  @cascade_action :cascade_notify_managers

  @doc """
  Enqueue the cascade dispatch for an allowlisted slice-change event, else no-op.
  Returns `:ok`. Content-free payload (spec §10): `slice_key` / `cursor` /
  `event_at` only — NO cap values, NO caller, NO member list.
  """
  @spec maybe_enqueue(map() | term()) :: :ok
  def maybe_enqueue(%{self_uri: %URI{scheme: scheme} = self_uri, slice_key: slice_key} = ev)
      when is_atom(slice_key) and is_binary(scheme) do
    if {scheme, slice_key} in @cascade_allowlist do
      cmd = %Ezagent.Cmd{
        target: self_uri,
        action: @cascade_action,
        args: %{
          slice_key: slice_key,
          cursor: Map.get(ev, :cursor),
          event_at: Map.get(ev, :at)
        },
        # `:vm_internal` is the trusted in-VM caller marker (#154). It is the
        # PROVENANCE SIGNAL the `:cascade_notify_managers` handler gates on: only
        # this internal self-dispatch carries it, so an external `/api/v1` caller
        # (whose `ctx.caller` is the authenticated entity `%URI{}`, transport-set)
        # can never forge it. Also cleanly bypasses `workspace_isolation_check`
        # (a `:vm_internal` caller has no workspace to mismatch).
        ctx: %{caller: :vm_internal, reply: :ignore},
        origin: :trusted_internal
      }

      Ezagent.Kind.DeferredDispatch.enqueue([cmd])
    end

    :ok
  end

  def maybe_enqueue(_), do: :ok
end
