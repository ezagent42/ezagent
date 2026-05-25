defmodule Ezagent.TemplateCapsTest do
  @moduledoc """
  Phase 7 PR 39 invariant — `template:read` / `template:write` /
  `template:instantiate` cap kinds are recognized by
  `Ezagent.Capability.matches?/2` and follow the documented semantics
  (Decision #136, GLOSSARY entry "template:read / template:write /
  template:instantiate").

  Background: cap `kind` field is an open atom — any atom is legal.
  PR 39 doesn't ADD code (the cap shape "just works" because
  atoms are open); it codifies the SEMANTIC contract via this
  invariant test so future PRs can't silently break the three-cap
  partition:

  - `template:read` — orchestrator's `list_templates` tool needs
    this to see candidate templates
  - `template:write` — orchestrator's `update_template` (merge to
    parent) requires write cap on the parent name
  - `template:instantiate` — Generator (`spawn_from_template/2`)
    CapBAC gate; default-granted with `template:read`

  This test pins the cap struct shape + matching behavior. PR 41's
  Generator CapBAC and PR 46's orchestrator tools rely on these
  semantics; if a future refactor flips, say, `:template` →
  `:tpl`, this test fails and the contract violation surfaces in
  CI rather than as a silent denial at runtime.

  Phase 9 PR-3 (SPEC v3 §4): template-kind caps are workspace-
  scoped same as session caps; the helper threads
  `workspace_uri: workspace://team-alpha` through both sides.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Capability
  import Ezagent.Test.CapHelper

  defp template_cap(behavior_atom, instance) do
    cap(
      kind: :template,
      behavior: behavior_atom,
      instance: instance,
      granted_by: URI.parse("entity://user/system/admin"),
      granted_at: ~U[2026-05-18 00:00:00Z]
    )
  end

  defp needed_template_action(behavior_atom, instance_uri) do
    needed(
      kind: :template,
      behavior: behavior_atom,
      instance: instance_uri
    )
  end

  describe "template:read cap" do
    test "matches when needed action is template:read on the granted instance" do
      template_uri = URI.parse("template://session/team-alpha/code-review@abc123")
      c = template_cap(:read, template_uri)

      n = needed_template_action(:read, template_uri)
      assert Capability.matches?(c, n)
    end

    test "does NOT match template:write needed (read is strictly narrower)" do
      template_uri = URI.parse("template://session/team-alpha/code-review@abc123")
      c = template_cap(:read, template_uri)

      n = needed_template_action(:write, template_uri)

      refute Capability.matches?(c, n),
             "template:read MUST NOT match template:write — orchestrator with read-only " <>
               "access must not be able to update_template (Decision #136)"
    end
  end

  describe "template:write cap" do
    test "matches when needed action is template:write on the granted instance" do
      template_uri = URI.parse("template://session/team-alpha/code-review@abc123")
      c = template_cap(:write, template_uri)

      n = needed_template_action(:write, template_uri)
      assert Capability.matches?(c, n)
    end

    test "does NOT match template:write on a different instance" do
      cap_uri = URI.parse("template://session/team-alpha/code-review@abc123")
      other_uri = URI.parse("template://session/team-alpha/other-team@xyz789")
      c = template_cap(:write, cap_uri)

      n = needed_template_action(:write, other_uri)

      refute Capability.matches?(c, n),
             "template:write on instance X must not match template:write on instance Y " <>
               "— write authority is per-template-instance (per-name actually, but " <>
               "this test pins the per-URI-instance check first)"
    end
  end

  describe "template:instantiate cap" do
    test "matches when needed action is template:instantiate on the granted instance" do
      template_uri = URI.parse("template://session/team-alpha/code-review@abc123")
      c = template_cap(:instantiate, template_uri)

      n = needed_template_action(:instantiate, template_uri)
      assert Capability.matches?(c, n)
    end

    test "does NOT match template:write needed (instantiate ≠ write)" do
      template_uri = URI.parse("template://session/team-alpha/code-review@abc123")
      c = template_cap(:instantiate, template_uri)

      n = needed_template_action(:write, template_uri)

      refute Capability.matches?(c, n),
             "template:instantiate MUST NOT match template:write — users who can " <>
               "spin up a session from a template must not be able to modify the " <>
               "template itself (Decision #136 + #141 fork model)"
    end
  end

  describe "template:any wildcard" do
    test "template:any matches all three actions on the granted instance" do
      template_uri = URI.parse("template://session/team-alpha/code-review@abc123")
      c = template_cap(:any, template_uri)

      for action <- [:read, :write, :instantiate] do
        n = needed_template_action(action, template_uri)

        assert Capability.matches?(c, n),
               "template:any cap should match template:#{action} on the same instance"
      end
    end
  end

  describe "kind boundary" do
    test "template:read on instance X does NOT match action targeting :session kind" do
      template_uri = URI.parse("template://session/team-alpha/x@hash")
      c = template_cap(:read, template_uri)

      n =
        needed(
          kind: :session,
          behavior: :read,
          instance: URI.parse("session://default/team-alpha/x")
        )

      refute Capability.matches?(c, n),
             "template cap must not leak into :session kind — kind boundary is strict"
    end
  end
end
