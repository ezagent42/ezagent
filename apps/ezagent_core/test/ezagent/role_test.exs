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
      # RF-6: `passive` defaults to false (a role yields a PRINCIPAL actor unless
      # the recipe explicitly opts into non-principal/passive).
      assert role.passive == false
    end

    test "RF-6: passive field — nil/absent → false, true → true, coerced + validated" do
      # absent → false
      assert {:ok, %{passive: false}} = Role.new(%{})
      # explicit nil → false (the principal default)
      assert {:ok, %{passive: false}} = Role.new(%{passive: nil})
      # explicit false → false
      assert {:ok, %{passive: false}} = Role.new(%{passive: false})
      # explicit true → true
      assert {:ok, %{passive: true}} = Role.new(%{passive: true})
      # STRING-keyed (persisted JSON/snapshot round-trip)
      assert {:ok, %{passive: true}} = Role.new(%{"passive" => true})
      assert {:ok, %{passive: false}} = Role.new(%{"passive" => false})
      # non-boolean → fail loud (not silently coerced to a surprising truth value)
      assert {:error, {:invalid_role_field, :passive, "yes"}} = Role.new(%{passive: "yes"})
      assert {:error, {:invalid_role_field, :passive, 1}} = Role.new(%{passive: 1})
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

      # a DUPLICATE-axis cap (both atom + string form of the same axis) is
      # ambiguous → rejected (would make normalize! branch selection
      # non-deterministic).
      dup = %{:behavior => SomeBehavior, "behavior" => "B", :action => :send}

      assert {:error, {:invalid_role_field, :requested_caps, _}} =
               Role.new(%{requested_caps: [dup]})
    end

    test "validates + canonicalizes behavior entries (string module names → atoms; rejects non-modules)" do
      # atom modules pass through
      assert {:ok, %{behaviors: [Ezagent.Behavior.Sandbox]}} =
               Role.new(%{behaviors: [Ezagent.Behavior.Sandbox]})

      # persisted string module names are canonicalized to the module atom
      assert {:ok, %{behaviors: [Ezagent.Behavior.Sandbox]}} =
               Role.new(%{"behaviors" => ["Ezagent.Behavior.Sandbox"]})

      assert {:ok, %{behaviors: [Ezagent.Behavior.Sandbox]}} =
               Role.new(%{"behaviors" => ["Elixir.Ezagent.Behavior.Sandbox"]})

      # non-module / malformed entries are rejected fail-loud
      assert {:error, {:invalid_role_field, :behaviors, "No.Such.Module"}} =
               Role.new(%{"behaviors" => ["No.Such.Module"]})

      assert {:error, {:invalid_role_field, :behaviors, nil}} =
               Role.new(%{behaviors: [nil]})

      assert {:error, {:invalid_role_field, :behaviors, :not_a_module}} =
               Role.new(%{behaviors: [:not_a_module]})

      # a LOADED but non-Behavior module is rejected (must be a real new-style
      # Ezagent Behavior, not just any loadable module)
      assert {:error, {:invalid_role_field, :behaviors, String}} =
               Role.new(%{behaviors: [String]})

      assert {:error, {:invalid_role_field, :behaviors, "String"}} =
               Role.new(%{"behaviors" => ["String"]})
    end

    test "rejects non-string skills/plugins entries" do
      assert {:error, {:invalid_role_field, :skills, _}} = Role.new(%{skills: [:atom_not_string]})
      assert {:error, {:invalid_role_field, :plugins, _}} = Role.new(%{plugins: [123]})
    end

    test "rejects a cap template that SMUGGLES a materialization/provenance axis" do
      # a role is workspace-agnostic — these axes are injected at materialization
      # / stamped at grant, never authored into the recipe. Smuggling a concrete
      # workspace_uri would be a cross-workspace CapBAC hole.
      for axis <- [:kind, :instance, :workspace_uri, :granted_by, :granted_at] do
        cap = Map.merge(%{behavior: SomeBehavior, action: :send}, %{axis => "smuggled"})

        assert {:error, {:invalid_role_field, :requested_caps, _}} =
                 Role.new(%{requested_caps: [cap]}),
               "expected atom-keyed #{axis} to be rejected"

        cap_str = %{"behavior" => "B", "action" => "send", Atom.to_string(axis) => "smuggled"}

        assert {:error, {:invalid_role_field, :requested_caps, _}} =
                 Role.new(%{"requested_caps" => [cap_str]}),
               "expected string-keyed #{axis} to be rejected"
      end
    end

    test "canonicalizes a string-keyed cap template's KEYS to atoms (values stay → PR-1b mints)" do
      assert {:ok, role} =
               Role.new(%{
                 "requested_caps" => [
                   %{"behavior" => "Ezagent.Behavior.Chat", "action" => "send"}
                 ]
               })

      # KEYS atomized (uniform → no mixed-key normalize! ambiguity); VALUES left
      # for PR-1b's normalize!/context-injection.
      assert [%{behavior: "Ezagent.Behavior.Chat", action: "send"}] = role.requested_caps

      assert {:error, {:invalid_role_field, :skills, "nope"}} =
               Role.new(%{"skills" => "nope"})

      assert {:error, {:invalid_role_field, :prompt, 123}} =
               Role.new(%{"prompt" => 123})
    end
  end
end
