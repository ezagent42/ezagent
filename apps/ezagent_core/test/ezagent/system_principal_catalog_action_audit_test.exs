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
  # SPEC §5 C2 — codex r4 MED-2 fix: per-codex evidence,
  # `system://lv-anon-mount` has empty caps (catalog.ex:272) — NOT a
  # wildcard holder; the `no_wildcard_system_principals_test.exs`
  # already exempts empty-cap entries, so we don't list lv-anon-mount
  # here.
  @wildcard_allowlist MapSet.new([
                        "system://bootstrap",
                        "system://mix-task",
                        "system://chat-router",
                        "system://chat-reply",
                        "system://boot-reconciler",
                        "system://template-materialize",
                        "system://orchestrator-tools",
                        "system://session-internal",
                        "system://workspace-loader",
                        "system://feishu-binding-policy"
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
