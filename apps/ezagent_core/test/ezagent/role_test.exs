defmodule Ezagent.RoleTest do
  use ExUnit.Case, async: true

  alias Ezagent.Role

  # Task #54 PR-1 §2.1 — a Role is the FLAVOR-AGNOSTIC sandbox-content recipe
  # (the content of a `template://<ws>/role/<name>` Template). It names skills,
  # plugins, a prompt persona, the behavior subset, REQUESTED caps (authorized
  # fail-closed at materialization — §2.3.1, never copied), and a
  # session-template REFERENCE. None of its fields may name a flavor
  # (cc/codex/curl, kind, bridge_adapter) — that re-entangles role with flavor.

  describe "new/1" do
    test "builds a %Role{} from a full recipe map" do
      assert {:ok, role} =
               Role.new(%{
                 skills: ["orchestrator"],
                 plugins: ["np"],
                 prompt: "you are an orchestrator",
                 behaviors: [Ezagent.Behavior.Sandbox],
                 requested_caps: [%{behavior: Ezagent.Behavior.Pty, action: :drive}],
                 session_template: "template://system/session/orchestrator"
               })

      assert role.skills == ["orchestrator"]
      assert role.plugins == ["np"]
      assert role.prompt == "you are an orchestrator"
      assert role.behaviors == [Ezagent.Behavior.Sandbox]
      assert role.requested_caps == [%{behavior: Ezagent.Behavior.Pty, action: :drive}]
      assert role.session_template == "template://system/session/orchestrator"
    end

    test "defaults empty/absent recipe fields" do
      assert {:ok, role} = Role.new(%{})
      assert role.skills == []
      assert role.plugins == []
      assert role.behaviors == []
      assert role.requested_caps == []
      assert role.prompt == nil
      assert role.session_template == nil
    end

    test "rejects a recipe that names a FLAVOR field (must be flavor-agnostic)" do
      for flavor_field <- [:flavor, :kind, :bridge_adapter, :template_class] do
        assert {:error, {:flavor_field_in_role, ^flavor_field}} =
                 Role.new(Map.put(%{skills: ["x"]}, flavor_field, "cc"))
      end
    end

    test "rejects a STRING-keyed flavor field too (persisted JSON/snapshot content)" do
      for flavor_field <- [:flavor, :kind, :bridge_adapter, :template_class] do
        assert {:error, {:flavor_field_in_role, ^flavor_field}} =
                 Role.new(%{"skills" => ["x"], Atom.to_string(flavor_field) => "cc"})
      end
    end

    test "reads STRING-keyed recipe fields (persisted content round-trip)" do
      assert {:ok, role} =
               Role.new(%{
                 "skills" => ["orchestrator"],
                 "prompt" => "persona",
                 "session_template" => "template://system/session/orchestrator"
               })

      assert role.skills == ["orchestrator"]
      assert role.prompt == "persona"
      assert role.session_template == "template://system/session/orchestrator"
    end

    test "rejects malformed recipe shapes at the boundary (no crash deferred to Compose)" do
      assert {:error, {:invalid_role_field, :behaviors, nil}} =
               Role.new(%{"behaviors" => nil})

      assert {:error, {:invalid_role_field, :requested_caps, "x"}} =
               Role.new(%{"requested_caps" => "x"})

      # requested_caps must be a list of cap-template MAPS (not bare atoms/tuples)
      assert {:error, {:invalid_role_field, :requested_caps, _}} =
               Role.new(%{requested_caps: [:not_a_cap_map]})

      # a cap-template map must carry behavior + action (else it crashes the policy predicate)
      assert {:error, {:invalid_role_field, :requested_caps, _}} =
               Role.new(%{requested_caps: [%{}]})

      assert {:error, {:invalid_role_field, :requested_caps, _}} =
               Role.new(%{requested_caps: [%{behavior: SomeBehavior}]})
    end

    test "accepts string-keyed cap templates carrying behavior + action" do
      assert {:ok, role} =
               Role.new(%{
                 "requested_caps" => [
                   %{"behavior" => "Ezagent.Behavior.Chat", "action" => "send"}
                 ]
               })

      assert [%{"behavior" => "Ezagent.Behavior.Chat", "action" => "send"}] = role.requested_caps

      assert {:error, {:invalid_role_field, :skills, "nope"}} =
               Role.new(%{"skills" => "nope"})

      assert {:error, {:invalid_role_field, :prompt, 123}} =
               Role.new(%{"prompt" => 123})
    end
  end
end
