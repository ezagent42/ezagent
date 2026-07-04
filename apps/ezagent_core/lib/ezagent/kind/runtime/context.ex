defmodule Ezagent.Kind.Runtime.Context do
  @moduledoc false

  # Phase 7 PR 43 — derive session URI from target URI for ctx enrichment.
  #
  # Sources covered:
  # - `session://default/team-alpha/main?action=session.send` → `session://default/team-alpha/main` (legacy 1-seg)
  # - `session://default/team-alpha/main` → `session://default/team-alpha/main` (already session)
  # - `entity://agent/team-alpha/cc_demo?action=session.receive` → nil (not session-targeted)
  # - any non-session URI → nil
  #
  # Pure URI manipulation; no registry / dispatch / GenServer involvement.
  # Returning `nil` for non-session targets is correct — a cap with
  # `{:within_session, S}` shape should not match when the dispatch
  # isn't even session-scoped, and `Capability.instance_match?/2` is
  # designed to handle nil session_uri (returns false for the tuple
  # case, preserving deny-as-default).
  # Allen 2026-05-26 (codex CRIT-1 closure) — inject the OPT-IN
  # `ctx[:sibling_slices]` read view scoped to ONLY the slice keys the
  # Behavior declared via `Ezagent.ActionSet.reads_sibling_slices/0`
  # (legacy) / `reads_siblings/0` (Lifecycle rename, SPEC §2.2).
  #
  # Lifecycle Phase A (SPEC §2.2 / §7 OQ-7, F2) — the Phase B coexistence
  # invariant: conversion order must NOT matter. A sibling slice may be
  # legacy-flat (`%{keys: ...}`) OR Lifecycle two-container
  # (`%{state: %{keys: ...}, transients: %{}}`) depending on whether that
  # sibling's module has been converted yet. We NORMALIZE every two-
  # container sibling to its persistent `:state` view so a legacy reader
  # (`ctx.sibling_slices[:api_keys][:keys]`) sees flat fields unchanged
  # regardless of the sibling's conversion state. We ALSO surface the
  # SPEC-promised Lifecycle `ctx.siblings` map (same normalized-flat
  # shape) for converted modules that read `ctx.siblings[:api_keys]`.
  # Both keys carry the SAME normalized-flat values, so ANY mix of
  # legacy/Lifecycle siblings + ANY mix of legacy/Lifecycle readers on
  # one Kind is correct.
  #
  # Read-only by Behavior contract; the Runtime ignores any mutation to
  # either ctx key — only the dispatching Behavior's own slice is the
  # writable target.
  def maybe_inject_sibling_slices(ctx, behavior_module, state) do
    case Ezagent.ActionSet.reads_siblings_of(behavior_module) do
      [] ->
        ctx

      keys when is_list(keys) ->
        siblings =
          for key <- keys, into: %{} do
            {key, normalize_sibling_slice(Map.get(state, key, %{}))}
          end

        ctx
        |> Map.put(:sibling_slices, siblings)
        |> Map.put(:siblings, siblings)
    end
  end

  # Normalize a sibling slice to its persistent flat view. A Lifecycle
  # two-container slice (`%{state: _, transients: _}`) collapses to its
  # `:state` sub-map; a legacy flat slice passes through unchanged. This
  # is what makes a reader's `ctx.siblings[:api_keys][:keys]` resolve
  # whether or not `:api_keys` has been converted to Lifecycle yet.
  defp normalize_sibling_slice(%{state: st, transients: _} = _slice) when is_map(st), do: st
  defp normalize_sibling_slice(other), do: other

  def derive_session_uri(%URI{scheme: "session"} = target) do
    # PR #141 SPEC v2: session URIs are `session://<type>/<name>`
    # (uniform 2-segment). Use Ezagent.URI.instance/1 to strip any
    # sub-resource so the result is the canonical instance form.
    Ezagent.URI.instance(target)
  end

  def derive_session_uri(_other), do: nil
end
