defmodule Ezagent.Role.MaterializeTest do
  use ExUnit.Case, async: false

  alias Ezagent.AgentFlavorRegistry
  alias Ezagent.Capability
  alias Ezagent.Role
  alias Ezagent.Role.Materialize

  # Task #54 §2.3 / §6 — the role × flavor materialization step + its COMPLETION
  # INVARIANT: the SAME role materialized against TWO different flavors yields
  # IDENTICAL sandbox CONTENTS (skills / plugins / prompt) while the behaviors
  # (role ∪ flavor) and the flavor-validated effective caps may legitimately
  # differ. This is the heart of the role-over-flavor decoupling — it fails today
  # (roles can't compose across flavors) and passes only once role × flavor
  # decouples via `Compose` (contents/behaviors) + `CapMint` (fail-closed caps).
  #
  # Dummy kind/template_class modules. `Materialize` derives the cap `:kind` axis
  # from the flavor Kind's `type_name/0` (mirroring the runtime dispatch check) and
  # consumes the flavor's `:instance_behaviors`; template_class is stored opaquely
  # (the spawn path that dereferences it is PR-2's live wiring).
  defmodule DummyKind do
    def type_name, do: :agent
  end

  # A dedicated-kind flavor whose Kind type differs from :agent — proves the cap
  # kind axis FOLLOWS the flavor's Kind, it is not hard-coded.
  defmodule WorkerKind do
    def type_name, do: :worker
  end

  # A Kind module that does NOT expose type_name/0 — cap kind is undeterminable.
  defmodule NoTypeNameKind do
  end

  # A Kind whose type_name/0 returns the `:any` wildcard — minting a cap with
  # kind `:any` would widen the grant across Kind boundaries, so it must fail
  # closed (NOT mint a wildcard-kind cap).
  defmodule AnyKind do
    def type_name, do: :any
  end

  # A Kind whose type_name/0 RAISES — must fail closed, not crash materialize.
  defmodule RaisingKind do
    def type_name, do: raise("boom")
  end

  defmodule DummyTC do
  end

  defp ctx do
    %{
      instance: Ezagent.URI.agent("team-alpha", "cc_demo"),
      workspace_uri: Ezagent.URI.workspace("team-alpha"),
      granter: Ezagent.URI.user("team-alpha", "alice")
    }
  end

  defp register_flavor(behaviors), do: register_flavor_with(DummyKind, behaviors)

  defp register_flavor_with(kind, behaviors) do
    flavor = "mat-flavor-#{System.unique_integer([:positive])}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: kind,
        template_class: DummyTC,
        instance_behaviors: fn -> behaviors end
      })

    flavor
  end

  describe "materialize/4 — the §6 completion invariant" do
    test "same role × two flavors → IDENTICAL sandbox_content; behaviors = role ∪ flavor" do
      {:ok, role} =
        Role.new(%{
          skills: ["orchestrator-skill"],
          plugins: ["orchestrator-plugin"],
          prompt: "you are the orchestrator",
          behaviors: [Ezagent.Behavior.Sandbox],
          requested_caps: [%{behavior: Ezagent.Behavior.Sandbox, action: :read}]
        })

      flavor_a = register_flavor([Ezagent.Behavior.Presence])
      flavor_b = register_flavor([Ezagent.Behavior.Routing])

      assert {:ok, ma} = Materialize.materialize(role, flavor_a, ctx(), fn _ -> true end)
      assert {:ok, mb} = Materialize.materialize(role, flavor_b, ctx(), fn _ -> true end)

      # THE invariant — contents are flavor-independent (byte-identical)
      assert ma.sandbox_content == mb.sandbox_content

      assert ma.sandbox_content == %{
               skills: ["orchestrator-skill"],
               plugins: ["orchestrator-plugin"],
               prompt: "you are the orchestrator"
             }

      # behaviors are the role's ∪ the flavor's — so they DIFFER by flavor
      assert Ezagent.Behavior.Sandbox in ma.behaviors
      assert Ezagent.Behavior.Presence in ma.behaviors
      assert Ezagent.Behavior.Sandbox in mb.behaviors
      assert Ezagent.Behavior.Routing in mb.behaviors
      refute Ezagent.Behavior.Routing in ma.behaviors
    end

    test "NEGATIVE authz (§2.3.1): a requested cap is granted where the policy permits, REJECTED where it does not — flavor-validated, not copied" do
      {:ok, role} =
        Role.new(%{requested_caps: [%{behavior: Ezagent.Behavior.Sandbox, action: :read}]})

      flavor_a = register_flavor([])
      flavor_b = register_flavor([])

      # flavor A's policy permits the requested cap; flavor B's rejects it
      assert {:ok, on_a} = Materialize.materialize(role, flavor_a, ctx(), fn _ -> true end)

      assert {:ok, on_b} =
               Materialize.materialize(role, flavor_b, ctx(), fn %{action: a} -> a != :read end)

      assert [%Capability{action: :read, behavior: Ezagent.Behavior.Sandbox}] = on_a.caps
      # rejected fail-closed — NOT copied
      assert on_b.caps == []
    end

    test "minted caps carry the materialization axes from ctx" do
      {:ok, role} =
        Role.new(%{requested_caps: [%{behavior: Ezagent.Behavior.Sandbox, action: :read}]})

      flavor = register_flavor([])
      c = ctx()

      assert {:ok, m} = Materialize.materialize(role, flavor, c, fn _ -> true end)
      assert [%Capability{} = cap] = m.caps
      assert cap.kind == :agent
      assert URI.to_string(cap.instance) == URI.to_string(c.instance)
      assert URI.to_string(cap.workspace_uri) == URI.to_string(c.workspace_uri)
      assert URI.to_string(cap.granted_by) == URI.to_string(c.granter)
    end

    test "the cap kind axis FOLLOWS the flavor's Kind type_name (not hard-coded :agent)" do
      {:ok, role} =
        Role.new(%{requested_caps: [%{behavior: Ezagent.Behavior.Sandbox, action: :read}]})

      flavor = register_flavor_with(WorkerKind, [])

      assert {:ok, m} = Materialize.materialize(role, flavor, ctx(), fn _ -> true end)
      assert [%Capability{kind: :worker}] = m.caps
    end

    test "fail-closed when the flavor's Kind cannot supply a type_name" do
      {:ok, role} =
        Role.new(%{requested_caps: [%{behavior: Ezagent.Behavior.Sandbox, action: :read}]})

      flavor = register_flavor_with(NoTypeNameKind, [])

      assert {:error, {:flavor_kind_undetermined, NoTypeNameKind}} =
               Materialize.materialize(role, flavor, ctx(), fn _ -> true end)
    end

    test "fail-closed when the flavor's Kind type_name is the :any wildcard (no wildcard-kind grant)" do
      {:ok, role} =
        Role.new(%{requested_caps: [%{behavior: Ezagent.Behavior.Sandbox, action: :read}]})

      flavor = register_flavor_with(AnyKind, [])

      assert {:error, {:flavor_kind_undetermined, AnyKind}} =
               Materialize.materialize(role, flavor, ctx(), fn _ -> true end)
    end

    test "fail-closed (no crash) when the flavor's Kind type_name/0 raises" do
      {:ok, role} =
        Role.new(%{requested_caps: [%{behavior: Ezagent.Behavior.Sandbox, action: :read}]})

      flavor = register_flavor_with(RaisingKind, [])

      assert {:error, {:flavor_kind_undetermined, RaisingKind}} =
               Materialize.materialize(role, flavor, ctx(), fn _ -> true end)
    end

    test "fail-closed on an unknown flavor — no composition" do
      {:ok, role} = Role.new(%{})
      unknown = "mat-none-#{System.unique_integer([:positive])}"

      assert {:error, {:unknown_flavor, ^unknown}} =
               Materialize.materialize(role, unknown, ctx(), fn _ -> true end)
    end

    test "a flavor with no per-instance behaviors (instance_behaviors nil) contributes none" do
      {:ok, role} = Role.new(%{behaviors: [Ezagent.Behavior.Sandbox]})
      flavor = "mat-nilbe-#{System.unique_integer([:positive])}"

      :ok =
        AgentFlavorRegistry.register(%{flavor: flavor, kind: DummyKind, template_class: DummyTC})

      assert {:ok, m} = Materialize.materialize(role, flavor, ctx(), fn _ -> true end)
      assert m.behaviors == [Ezagent.Behavior.Sandbox]
    end
  end
end
