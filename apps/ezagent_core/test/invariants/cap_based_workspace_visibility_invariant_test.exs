defmodule EzagentCore.Invariants.CapBasedWorkspaceVisibilityInvariantTest do
  @moduledoc """
  SPEC 2026-05-27-workspace-cap-based-visibility §5 — the merge gate
  invariant for cap-based workspace visibility.

  Per `feedback_completion_requires_invariant_test`: this PR is
  "done" iff this test passes AND would fail when the architectural
  goal is unmet. Each INV below is designed to fail when a specific
  partial impl is shipped:

  - INV-1: regular non-admin caller sees `[]` — fails if the impl
    returns `list_all/0` for everyone.
  - INV-2: workspace member sees their workspace — fails if the
    membership branch is dropped.
  - INV-3 / INV-3a: the structural admin shortcut fires for
    member_of_system and home_is_system. INV-3b proves an unsigned legacy
    wildcard is inert rather than bypassing the unified verifier.
  - INV-4: cap-scope branch contributes correctly — fails if cap-scope
    is dropped or if the admin shortcut over-fires.
  - INV-5: adding a member changes the visibility set with no extra
    cap grant.
  - INV-6: granting a scoped cap surfaces the cap-target workspace.
  - INV-7: the `workspace://system` negative direction — never visible
    to a non-admin regardless of which non-admin caps are added.
  - INV-8: code-shape meta-test — the boolean-restoration anti-pattern
    (`if ws.name == "system"`) is structurally rejected at the
    source level. INV-7 alone cannot catch this (the test fixture's
    chosen caps would still produce the correct list under the
    anti-pattern); INV-8 closes the gap.

  Per SPEC §9 — codex r1 review question #3: cannot pass with a
  partial impl. If a partial impl is found to pass, strengthen this
  test in the next round.
  """

  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.Capability
  alias Ezagent.Workspace
  alias Ezagent.Workspace.Store

  @system "system"
  @team_alpha "team-alpha"
  @team_beta "team-beta"

  # Setup: 3 persisted workspaces; the chat plugin's
  # `ensure_system_workspace/0` may have seeded "system" already.
  defp setup_workspaces do
    Enum.each([@system, @team_alpha, @team_beta], fn name ->
      case Store.get_by_name(name) do
        nil -> {:ok, _} = Store.create(name, %{})
        _ -> :ok
      end
    end)
  end

  # Legacy unsigned wildcard shape. SystemPrincipal has been eliminated and
  # this artifact must never grant visibility without a concrete current target.
  defp bootstrap_wildcard_cap do
    %Capability{
      kind: :any,
      behavior: :any,
      action: :any,
      instance: :any,
      workspace_uri: :any,
      granted_by: Ezagent.URI.user(:system, :admin),
      granted_at: DateTime.utc_now()
    }
  end

  defp scoped_workspace_cap(workspace_name, caller) do
    ws_uri = Ezagent.URI.new!("workspace://#{workspace_name}")

    requested =
      Capability.cap(
        :workspace,
        Ezagent.ActionSet.Workspace,
        :list_members,
        ws_uri,
        ws_uri
      )

    Ezagent.Test.CapHelper.with_test_authority(ws_uri, :workspace, fn authority ->
      Ezagent.Test.CapHelper.authority_signed_cap!(authority, caller, requested)
    end)
  end

  defp licensed_caller(label, workspace \\ @team_alpha) do
    caller =
      Ezagent.URI.user(
        workspace,
        "#{label}-#{System.unique_integer([:positive])}"
      )

    {:ok, _row} = Ezagent.Users.create_read_only(caller, [])
    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: caller, initial_caps: []})

    on_exit(fn -> _ = Ezagent.Kind.terminate(caller) end)
    wait_until_ready(caller)
    caller
  end

  defp current_caps(caller, extra \\ []) do
    caller
    |> Ezagent.EntityCaps.load()
    |> MapSet.new()
    |> MapSet.union(MapSet.new(extra))
  end

  defp wait_until_ready(uri, attempts \\ 100)
  defp wait_until_ready(_uri, 0), do: flunk("principal did not become ready")

  defp wait_until_ready(uri, attempts) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        Process.sleep(10)
        wait_until_ready(uri, attempts - 1)
    end
  end

  defp names(workspaces), do: workspaces |> Enum.map(& &1.name) |> Enum.sort()

  describe "list_workspaces_for/2 — basic visibility" do
    test "INV-1: regular non-admin caller with no caps and no membership sees []" do
      setup_workspaces()

      caller = Ezagent.URI.new!("entity://team-alpha/user/regular")

      result = Workspace.list_workspaces_for(caller, MapSet.new())

      assert names(result) == [],
             "INV-1 violation: regular non-admin caller saw " <>
               "#{inspect(names(result))} — expected []. The impl returns " <>
               "list_all/0 (or otherwise leaks workspaces) for non-admin " <>
               "callers; cap-scope and membership branches both produce []."
    end

    test "INV-2: workspace member sees exactly their workspace" do
      setup_workspaces()

      caller = licensed_caller("member")
      {:ok, _} = Workspace.Store.update_members(@team_alpha, [caller])

      result = Workspace.list_workspaces_for(caller, current_caps(caller))

      assert names(result) == [@team_alpha],
             "INV-2 violation: member of team-alpha saw " <>
               "#{inspect(names(result))} — expected [team-alpha]. The " <>
               "membership branch is dropped (or returns the empty list, " <>
               "or returns more than the member's own workspace)."
    end

    test "INV-3: caller in workspace://system.members sees all (member_of_system? path)" do
      setup_workspaces()

      caller = licensed_caller("promoted")
      {:ok, _} = Workspace.Store.update_members(@system, [caller])

      result = Workspace.list_workspaces_for(caller, current_caps(caller))

      assert names(result) == [@system, @team_alpha, @team_beta] |> Enum.sort(),
             "INV-3 violation: explicit system-member saw " <>
               "#{inspect(names(result))} — expected all 3. The " <>
               "member_of_system? predicate (iv) is not firing in the " <>
               "admin shortcut."
    end

    test "INV-3a: caller whose URI host is `system` sees all (home_is_system? path)" do
      setup_workspaces()

      # Home IS system; explicitly NOT in members to isolate path (iii).
      caller = licensed_caller("admin-created", @system)
      {:ok, _} = Workspace.Store.update_members(@system, [])

      result = Workspace.list_workspaces_for(caller, current_caps(caller))

      assert names(result) == [@system, @team_alpha, @team_beta] |> Enum.sort(),
             "INV-3a violation: home-is-system caller saw " <>
               "#{inspect(names(result))} — expected all 3. The " <>
               "home_is_system? predicate (iii) is not firing in the " <>
               "admin shortcut. This caller is admin-equivalent by URI " <>
               "host without explicit membership."
    end

    test "INV-3b: unsigned legacy bootstrap wildcard does not bypass current-generation verification" do
      setup_workspaces()

      # Home is team-alpha (NOT system); NOT in system.members; holds
      # the full 5-axis wildcard cap.
      caller = licensed_caller("wildcard")
      {:ok, _} = Workspace.Store.update_members(@system, [])

      result =
        Workspace.list_workspaces_for(caller, current_caps(caller, [bootstrap_wildcard_cap()]))

      assert names(result) == [],
             "INV-3b violation: an unsigned/unverifiable wildcard cap entered " <>
               "the admin shortcut without authorize/3"
    end

    test "INV-4: delegated workspace admin sees exactly their cap-scoped workspace" do
      setup_workspaces()

      # NOT a system member; NOT home-is-system; holds a SINGLE
      # narrowly-scoped Workspace cap on team-alpha (action: :list_members,
      # NOT :any — so does NOT pass holds_cross_workspace_admin_cap?
      # or holds_admin_caps?).
      caller = licensed_caller("delegated-admin")
      {:ok, _} = Workspace.Store.update_members(@system, [])
      {:ok, _} = Workspace.Store.update_members(@team_alpha, [])
      cap = scoped_workspace_cap(@team_alpha, caller)

      result = Workspace.list_workspaces_for(caller, current_caps(caller, [cap]))

      assert names(result) == [@team_alpha],
             "INV-4 violation: delegated workspace admin saw " <>
               "#{inspect(names(result))} — expected [team-alpha]. The " <>
               "cap-scope branch (§3.3.b) must contribute exactly the " <>
               "workspace whose URI matches the cap's `workspace_uri`. " <>
               "If this returns more than team-alpha, the admin shortcut " <>
               "is over-firing on a non-admin-shape cap; if it returns [], " <>
               "the cap-scope branch is dropped."
    end
  end

  describe "list_workspaces_for/2 — mutation regression" do
    test "INV-5: adding a member changes visibility set with no cap grant" do
      setup_workspaces()

      caller = licensed_caller("regular")

      # Initial state — no caps, no membership — sees [].
      assert names(Workspace.list_workspaces_for(caller, current_caps(caller))) == []

      # Add caller as member of team-beta. The membership branch
      # should now surface team-beta.
      {:ok, _} = Workspace.Store.update_members(@team_beta, [caller])

      result = Workspace.list_workspaces_for(caller, current_caps(caller))

      assert names(result) == [@team_beta],
             "INV-5 violation: adding a member did not surface their " <>
               "workspace via the membership branch. Got " <>
               "#{inspect(names(result))} — expected [team-beta]. The " <>
               "membership read must reflect post-write state."
    end

    test "INV-6: granting a scoped cap surfaces the cap-target workspace" do
      setup_workspaces()

      caller = licensed_caller("scoped-regular")
      cap = scoped_workspace_cap(@team_alpha, caller)

      result = Workspace.list_workspaces_for(caller, current_caps(caller, [cap]))

      assert names(result) == [@team_alpha],
             "INV-6 violation: granting a narrow Workspace cap on " <>
               "team-alpha did NOT surface team-alpha via the cap-scope " <>
               "branch. Got #{inspect(names(result))} — expected " <>
               "[team-alpha]. The cap-scope branch (§3.3.b) must compose " <>
               "with membership; a caller with no membership but a " <>
               "narrow cap should still see the cap-target."
    end

    test "INV-7: non-admin NEVER sees workspace://system regardless of non-admin caps" do
      setup_workspaces()

      caller = licensed_caller("multi-scoped-regular")
      {:ok, _} = Workspace.Store.update_members(@system, [])
      cap_a = scoped_workspace_cap(@team_alpha, caller)
      cap_b = scoped_workspace_cap(@team_beta, caller)

      result =
        Workspace.list_workspaces_for(caller, current_caps(caller, [cap_a, cap_b]))

      refute @system in names(result),
             "INV-7 violation: non-admin holding 2 narrow workspace caps " <>
               "saw workspace://system in the listing. Got " <>
               "#{inspect(names(result))}. The admin shortcut must NOT " <>
               "fire for this caller (no admin caps, no system membership, " <>
               "no home-is-system); system must be excluded by structural " <>
               "absence from the union, not by a literal-name filter."

      # Sanity: the narrow caps still surface their targets.
      assert names(result) == [@team_alpha, @team_beta] |> Enum.sort()
    end
  end

  describe "INV-8 — code-shape meta-test (boolean-restoration anti-pattern)" do
    @system_literal_targets [
      "apps/ezagent_domain_workspace/lib/ezagent/workspace.ex",
      "apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex"
    ]

    test "workspace.ex + store.ex do NOT contain the \"system\" literal in code scope" do
      # The repo root is 4 levels up from this invariant file
      # (apps/ezagent_core/test/invariants/ → apps/.. → repo root).
      repo_root = Path.expand("../../../..", __DIR__)

      violations =
        Enum.flat_map(@system_literal_targets, fn rel ->
          path = Path.join(repo_root, rel)
          src = File.read!(path)

          # Strip moduledocs / @doc heredocs, then strip line
          # comments. A legitimate "system" reference in moduledoc
          # or comment scope is allowed (we annotate the SPEC in
          # comments); the violation is the literal `"system"` in
          # code body — which would re-introduce the field-shaped
          # special-case in code form.
          sanitized =
            src
            |> String.replace(~r/@moduledoc\s+"""[\s\S]*?"""/, "")
            |> String.replace(~r/@doc\s+"""[\s\S]*?"""/, "")
            |> String.split("\n")
            |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
            |> Enum.join("\n")

          if Regex.match?(~r/"system"/, sanitized) do
            [rel]
          else
            []
          end
        end)

      assert violations == [],
             """
             INV-8 violation: source file(s) contain the literal "system" in
             code scope (outside moduledoc / @doc / line comments):

               #{Enum.join(violations, "\n               ")}

             This catches the boolean-restoration anti-pattern. A partial
             impl like

                 if workspace.name == "system" and !system_member, do: exclude

             would PASS INV-7 (the test fixture's regular user gets
             team-alpha + team-beta caps, so the literal-string filter
             correctly excludes system for the non-member). INV-7 cannot
             discriminate behavior between the correct impl and the
             literal-filter anti-pattern at the test fixtures' chosen cap
             shapes.

             The system workspace's hiding from non-members is STRUCTURAL
             (cap + membership absence), NOT a literal-match filter.
             Predicate-level membership lookup belongs in
             Ezagent.Capability.member_of_system?/1 (ezagent_core), which
             is a different file and a different semantic level.

             SPEC 2026-05-27-workspace-cap-based-visibility §5 INV-8 + OQ-4.
             """
    end
  end
end
