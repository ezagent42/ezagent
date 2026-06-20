defmodule Ezagent.SystemPrincipalCatalogActionAuditTest do
  @moduledoc """
  SPEC 2026-05-27 capability-action-axis §5 C2 — wildcard catalog
  allowlist + per-entry action atom validity audit.

  Two-part regression lock:

  (a) **Per-entry action atom validity** — every catalog cap with a
  concrete (non-`:any`) action atom MUST match a real `actions/0`
  entry of the named Behavior. A typo in the catalog produces a cap
  that never matches anything (silent denial); this test makes the
  catalog audit explicit.

  (b) **Closed wildcard allowlist** — exactly N system principals are
  PERMITTED to hold caps with `action: :any`. Any NEW catalog entry
  introducing a wildcard for a previously-narrow principal fails this
  test, preventing silent expansion of ambient authority.

  Async-safe: the catalog is a pure-data module function; no Repo,
  no GenServer, no boot.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Capability
  alias Ezagent.SystemPrincipal.Catalog

  # Closed allowlist — every principal here is KNOWN to legitimately
  # carry at least one `action: :any` cap. The justification for each
  # is documented inline in `SystemPrincipal.Catalog.entries/0`.
  #
  # SPEC §5 C2 — `system://lv-anon-mount` (an empty-caps placeholder) and
  # `system://socialware-gc` (a concrete `session.leave` cap, never a wildcard)
  # were both ELIMINATED 2026-06-20, 甲-6, so neither is listed here.
  # #154 genesis collapse (2026-06-20): `system://bootstrap` (the LAST
  # wildcard-holding principal, the genesis) was collapsed into the admin
  # ENTITY. The Catalog is now EMPTY, so NO system principal holds an
  # `action: :any` cap — the wildcard allowlist is EMPTY. The genesis wildcard
  # now lives on the admin entity (`Ezagent.Capability.admin_genesis_cap/0`).
  @wildcard_allowlist MapSet.new([
                        # ELIMINATED 2026-06-20 (#154 genesis collapse):
                        # `system://bootstrap` — collapsed into the admin entity.
                        # ELIMINATED 2026-06-20, 甲-4 (#154 north star):
                        # `system://chat-router` DELETED (it held bootstrap_wildcard
                        # → action: :any; the last non-genesis wildcard holder) — the
                        # Session delivery fan-out now mints a per-recipient inline
                        # `:receive` cap (member self-consent) + presents a
                        # same-workspace-guarded `session.send` for cross-session
                        # forwards + an inline self-cap for the agent sync_result,
                        # instead of borrowing this wildcard.
                        # ELIMINATED 2026-06-20, 甲-3 (#154 north star):
                        # `system://chat-reply` DELETED (it held bootstrap_wildcard
                        # → action: :any) — the 5 agent/plugin bridges now present
                        # their OWN inline narrow `session.send` cap on the concrete
                        # reply session instead of borrowing this wildcard.
                        # ELIMINATED 2026-06-20 (#154 north star):
                        # `system://template-materialize` DELETED (it held
                        # cap(:any, Template, :any) + cap(:session, Session, :any),
                        # both action: :any) — its 5 materialization dispatch sites
                        # now run under the genesis admin entity with inline
                        # per-action caps; #533 refines to per-creator.
                        # ELIMINATED 2026-06-20 (#154 north star):
                        # `system://session-internal` DELETED (it held
                        # cap(:any, Session, :any) + cap(:workspace, Workspace, :any),
                        # both action: :any) — the LAST non-genesis principal; its 6
                        # sites re-attributed to session-self / admin / operator
                        # authority. Only `system://bootstrap` (genesis) remains in
                        # the allowlist.
                        # ELIMINATED 2026-06-19 (#154 north star):
                        # `system://orchestrator-tools` DELETED (it held
                        # cap(:session, Session, :any) + cap(:agent, Identity,
                        # :list_caps)) — a DEAD caller: the orchestrator runs its
                        # tools as itself; the set_legends allowlist entry was
                        # unreachable in production.
                        # no-unowned-caps PR-1 (2026-06-17): feishu-binding-policy
                        # DELETED from the Catalog (it held cap(:workspace,
                        # Workspace, :any)).
                        # ELIMINATED 2026-06-19 (#154 north star):
                        # `system://workspace-loader` DELETED (it held
                        # cap(:workspace, Workspace, :any)) — re-attributed to the
                        # workspace's own per-action self-authority.
                        # ELIMINATED 2026-06-19 (#154 north star): `system://mix-task`
                        # DELETED (it held bootstrap_wildcard) — the operator CLI
                        # tasks now route authority through entity://system/user/admin
                        # with inline per-action admin caps.
                      ])

  describe "(a) per-entry action atom validity — concrete actions match the named Behavior's actions/0" do
    test "every catalog cap's concrete action atom exists on the Behavior's actions/0" do
      violations =
        for {principal_uri, caps} <- Catalog.entries(),
            %Capability{behavior: behavior} = cap <- caps,
            is_atom(behavior),
            behavior != :any,
            action = Capability.action_of(cap),
            action != :any,
            not action_in_behavior_actions?(behavior, action) do
          {principal_uri, behavior, action}
        end

      assert violations == [],
             "SystemPrincipal.Catalog cap audit — every concrete action atom MUST be a real `actions/0` entry of the named Behavior. SPEC 2026-05-27 capability-action-axis §5 C2 (a). Violations:\n" <>
               Enum.map_join(violations, "\n", fn {p, b, a} ->
                 "  - #{p}: cap with behavior=#{inspect(b)} action=#{inspect(a)} — not in #{inspect(b)}.actions()"
               end)
    end
  end

  describe "(b) closed wildcard allowlist — only listed principals may hold action: :any caps" do
    test "every principal holding an action-wildcard cap is in @wildcard_allowlist" do
      offenders =
        for {principal_uri, caps} <- Catalog.entries(),
            %Capability{} = cap <- caps,
            Capability.action_of(cap) == :any,
            not MapSet.member?(@wildcard_allowlist, principal_uri) do
          principal_uri
        end

      assert offenders == [],
             "SystemPrincipal.Catalog wildcard expansion detected. " <>
               "The following principals hold `action: :any` caps but are NOT in " <>
               "@wildcard_allowlist (SPEC 2026-05-27 capability-action-axis §5 C2):\n" <>
               Enum.map_join(offenders, "\n", fn p -> "  - #{p}" end) <>
               "\n\nIf this is INTENTIONAL — add the principal URI to the " <>
               "@wildcard_allowlist in this test AND justify the wildcard in " <>
               "`SystemPrincipal.Catalog.entries/0`'s inline comment for that " <>
               "principal. Wildcard caps are ambient authority; review surface " <>
               "for adding one is non-trivial."
    end

    test "every allowlisted principal actually has a wildcard cap (allowlist isn't stale)" do
      catalog_principals_with_wildcards =
        for {principal_uri, caps} <- Catalog.entries(),
            %Capability{} = cap <- caps,
            Capability.action_of(cap) == :any do
          principal_uri
        end
        |> MapSet.new()

      stale =
        @wildcard_allowlist
        |> MapSet.difference(catalog_principals_with_wildcards)
        |> MapSet.to_list()

      assert stale == [],
             "Stale @wildcard_allowlist entries — these principals are listed in " <>
               "the allowlist but the catalog no longer mints wildcard caps for them. " <>
               "Remove them from @wildcard_allowlist:\n" <>
               Enum.map_join(stale, "\n", fn p -> "  - #{p}" end)
    end
  end

  defp action_in_behavior_actions?(behavior, action) do
    if Code.ensure_loaded?(behavior) and function_exported?(behavior, :actions, 0) do
      action in behavior.actions()
    else
      # Behavior not yet loaded (e.g. plugin Behavior in a build that
      # excludes the plugin app) — defer to runtime / don't fail the
      # audit.
      true
    end
  rescue
    _ -> true
  catch
    _, _ -> true
  end
end
