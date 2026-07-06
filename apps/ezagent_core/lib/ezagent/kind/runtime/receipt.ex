defmodule Ezagent.Kind.Runtime.Receipt do
  @moduledoc """
  Reputation Receipt — the facts layer (minimal).

  A Receipt is the durable *exhaust* of the Cap-BAC authorization flow: when an
  authorized invocation actually crosses a workspace ("cross-org") boundary,
  `Ezagent.Kind.Runtime` records one factual `:receipt` EventLog row on the
  SUCCESS path. The row carries
  `{caller, provider, capability identity_key, action, trace_id, outcome,
  timestamp}` plus **reserved-but-empty** `signature` / `provenance_ref`
  fields — the schema is stable from day one so a future signing /
  provenance-composition upgrade needs no history migration (both are
  deliberately deferred for now).

  ## Why only cross-workspace

  Intra-workspace invocations are the overwhelming majority and are not
  reputation-meaningful (no cross-org authority was exercised). Restricting to
  genuine cross-org facts keeps the log to the reputation-relevant subset and
  avoids flooding.

  ## Non-negotiable: this is exhaust, not the product

  Receipt emission MUST NEVER break or slow the dispatch reply. Every failure
  is swallowed here (belt) AND inside `Ezagent.Kind.Runtime.Effects.emit_receipt/3`'s
  `execute_events` reuse (suspenders); `maybe_emit/5`'s return is discarded by
  the caller and is never threaded back into the dispatch `with` result.

  ## Predicate reuse

  `cross_workspace_invocation?/3` reuses the SAME building blocks as dispatch
  step 5.6 (`ActionSet.workspace_scoped?/1` gate + `Capability.workspace_of/1`
  on both endpoints + a workspace-equality compare). A cross-org fact requires
  the behavior to be workspace-scoped AND both endpoints to resolve to
  concrete, DIFFERENT workspaces — so workspace-agnostic behaviors and
  cross-cutting-scheme targets (`workspace_of → :any`) emit nothing, exactly as
  5.6 treats them.
  """

  require Logger

  @doc """
  Emit a cross-org Receipt fact on the dispatch SUCCESS path, if this
  invocation crossed a workspace boundary. Always returns `:ok`; every failure
  is swallowed so the dispatch reply is never affected.

  `matched_cap` is the step-5.5 authorizer (or `nil` when authorized via a
  slice-held cap / rule / exempt action). When `nil`, it falls back to the
  cross-workspace cap 5.6 relied on — always present in `ctx.caps` for a
  genuine cross-org call, since 5.6's `caps_have_cross_workspace?` reads
  `ctx.caps` only.
  """
  @spec maybe_emit(URI.t(), atom(), Ezagent.Capability.t() | nil, module(), map()) :: :ok
  def maybe_emit(%URI{} = target, action, matched_cap, behavior_module, ctx) do
    if cross_workspace_invocation?(behavior_module, target, ctx) do
      cap = matched_cap || cross_workspace_cap(ctx)

      # `if cap` guards the `identity_key(nil)` crash if neither the step-5.5
      # authorizer nor a cross-workspace cap is present (never expected on a
      # genuine cross-org dispatch that reached the success branch).
      if cap do
        provider = Ezagent.URI.instance(target)

        payload = %{
          caller: canonicalize_uri(Map.get(ctx, :caller)),
          provider: canonicalize_uri(provider),
          capability: canonicalize_identity_key(Ezagent.Capability.identity_key(cap)),
          action: action,
          trace_id: Map.get(ctx, :trace_id),
          outcome: :fulfilled,
          # Reserved-but-empty (lead-deferred signing + provenance-composition).
          signature: nil,
          provenance_ref: nil
        }

        # Reuse the `:emit`-effect append path (derives workspace_uri from the
        # aggregate, normalizes the caller, swallows all EventLog failures).
        # The aggregate IS the provider (the target Kind instance).
        _ = Ezagent.Kind.Runtime.Effects.emit_receipt(provider, payload, ctx)
      end
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "Ezagent.Kind.Runtime.Receipt: emission failed (continuing): #{Exception.message(e)}"
      )

      :ok
  catch
    _, _ -> :ok
  end

  # "Did THIS invocation cross a workspace boundary?" — mirrors step 5.6.
  defp cross_workspace_invocation?(behavior_module, target, ctx) do
    if Ezagent.ActionSet.workspace_scoped?(behavior_module) do
      caller_ws = workspace_of_caller(Map.get(ctx, :caller))
      target_ws = Ezagent.Capability.workspace_of(target)

      caller_ws != :any and target_ws != :any and not ws_equal?(caller_ws, target_ws)
    else
      false
    end
  end

  # The cross-workspace cap 5.6 relied on — same predicate
  # (`Capability.cross_workspace?/2`) `caps_have_cross_workspace?` uses, but
  # returns the cap (or nil) instead of a boolean.
  defp cross_workspace_cap(ctx) do
    caps = Map.get(ctx, :caps, MapSet.new())
    caller = Map.get(ctx, :caller)
    Enum.find(caps, fn cap -> Ezagent.Capability.cross_workspace?(cap, caller) end)
  end

  # Mirrors `Kind.Runtime`'s step-5.6 caller-workspace derivation.
  defp workspace_of_caller(:vm_internal), do: :any
  defp workspace_of_caller(nil), do: :any

  defp workspace_of_caller(%URI{} = uri) do
    Ezagent.Capability.workspace_of(uri)
  rescue
    _ -> :any
  end

  defp workspace_of_caller(_), do: :any

  defp ws_equal?(:any, _), do: true
  defp ws_equal?(_, :any), do: true

  defp ws_equal?(%URI{} = a, %URI{} = b),
    do: URI.to_string(a) == URI.to_string(b)

  defp ws_equal?(_, _), do: false

  # Canonicalize a URI (or already-string) to a JSON-safe string. Bare tuples
  # are NOT JSON-encodable, so every URI-bearing value in the receipt payload
  # is stringified before it reaches `Jason.encode!/1`.
  defp canonicalize_uri(%URI{} = u), do: URI.to_string(u)
  defp canonicalize_uri(s) when is_binary(s), do: s
  defp canonicalize_uri(nil), do: nil
  defp canonicalize_uri(other), do: inspect(other)

  # `Capability.identity_key/1` returns a 5-tuple whose `instance` /
  # `workspace_uri` axes are `%URI{}` structs (or scope tuples / `:any`) — a
  # bare tuple is not JSON-encodable. Flatten to a map of JSON-safe values.
  # `kind` / `behavior` / `action` are atoms (Jason encodes atoms to strings).
  defp canonicalize_identity_key({kind, behavior, action, instance, workspace_uri}) do
    %{
      kind: kind,
      behavior: behavior,
      action: action,
      instance: canonicalize_axis(instance),
      workspace_uri: canonicalize_axis(workspace_uri)
    }
  end

  defp canonicalize_axis(:any), do: "any"
  defp canonicalize_axis(%URI{} = u), do: URI.to_string(u)

  defp canonicalize_axis({tag, %URI{} = u}) when is_atom(tag),
    do: "#{tag}:#{URI.to_string(u)}"

  defp canonicalize_axis(other), do: inspect(other)
end
