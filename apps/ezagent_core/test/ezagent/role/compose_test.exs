defmodule Ezagent.Role.ComposeTest do
  use ExUnit.Case, async: true

  alias Ezagent.Role
  alias Ezagent.Role.Compose

  # Task #54 PR-1 §2.3 — materialize an agent from (role, flavor). The role
  # FILLS the sandbox (skills/plugins/prompt/behaviors); the flavor LOADS it.
  # §2.3.1 — caps are REQUESTED, authorized fail-closed (requested ∩ policy),
  # NEVER copied. The completion invariant (§6): same role × two flavors →
  # identical sandbox CONTENTS, flavor-VALIDATED (not identical) caps.

  defp role do
    {:ok, role} =
      Role.new(%{
        skills: ["orchestrator"],
        plugins: ["np"],
        prompt: "persona",
        behaviors: [Ezagent.Behavior.Sandbox],
        requested_caps: [
          %{behavior: Ezagent.Behavior.Pty, action: :drive},
          %{behavior: Ezagent.Behavior.Chat, action: :send}
        ]
      })

    role
  end

  # opts builder — flavor_kind + flavor_behaviors + a fail-closed policy predicate.
  defp opts(overrides \\ %{}) do
    Map.merge(
      %{flavor_behaviors: [], flavor_kind: :agent, authorize_cap: fn _ -> true end},
      Map.new(overrides)
    )
  end

  describe "materialize/2" do
    test "composes role behaviors with the flavor's behaviors (union, deduped)" do
      out =
        Compose.materialize(
          role(),
          opts(flavor_behaviors: [Ezagent.Behavior.Identity, Ezagent.Behavior.Sandbox])
        )

      assert Enum.sort(out.behaviors) ==
               Enum.sort([Ezagent.Behavior.Sandbox, Ezagent.Behavior.Identity])
    end

    test "sandbox CONTENTS are flavor-independent (same role → same content)" do
      cc = Compose.materialize(role(), opts(flavor_behaviors: [:cc_b], flavor_kind: :agent))
      codex = Compose.materialize(role(), opts(flavor_behaviors: [:codex_b], flavor_kind: :agent))

      assert cc.sandbox_content == codex.sandbox_content
      assert cc.sandbox_content == %{skills: ["orchestrator"], plugins: ["np"], prompt: "persona"}
    end

    test "injects the FLAVOR kind into each effective cap (closes the normalize! kind:any hole)" do
      out = Compose.materialize(role(), opts(flavor_kind: :agent))
      assert Enum.all?(out.effective_caps, &(&1.kind == :agent))

      # the SAME role under a different flavor kind → flavor-validated DIFFERING kind (§6)
      out2 = Compose.materialize(role(), opts(flavor_kind: :worker))
      assert Enum.all?(out2.effective_caps, &(&1.kind == :worker))
    end

    test "FAIL-CLOSED: a requested cap the policy rejects is NOT in effective_caps" do
      # policy permits :send but NOT :drive (e.g. a no-bridge flavor)
      out = Compose.materialize(role(), opts(authorize_cap: fn %{action: a} -> a == :send end))

      assert out.effective_caps == [
               %{behavior: Ezagent.Behavior.Chat, action: :send, kind: :agent}
             ]

      refute Enum.any?(out.effective_caps, &(&1.action == :drive))
    end

    test "all-permitted policy yields effective == requested (+ injected kind)" do
      out = Compose.materialize(role(), opts())

      expected = Enum.map(role().requested_caps, &Map.put(&1, :kind, :agent))
      assert out.effective_caps == expected
    end

    test "canonicalizes a realistic persisted JSON cap (string keys + values)" do
      # realistic persisted shape: string keys AND string values. Compose
      # canonicalizes behavior→module + action→atom + injects flavor kind, so an
      # atom/module-value policy predicate matches and effective_caps are
      # value-canonical (PR-1b then injects workspace + mints via normalize!).
      {:ok, r} =
        Role.new(%{
          "requested_caps" => [%{"behavior" => "Ezagent.Behavior.Sandbox", "action" => "read"}]
        })

      out = Compose.materialize(r, opts(authorize_cap: fn %{action: :read} -> true end))

      assert out.effective_caps ==
               [%{behavior: Ezagent.Behavior.Sandbox, action: :read, kind: :agent}]
    end

    test "an unresolvable behavior value stays a string → policy rejects it (fail-closed)" do
      {:ok, r} =
        Role.new(%{"requested_caps" => [%{"behavior" => "No.Such.Module", "action" => "read"}]})

      out = Compose.materialize(r, opts(authorize_cap: fn %{behavior: b} -> is_atom(b) end))
      assert out.effective_caps == []
    end

    test "effective_caps carry flavor kind + behavior/action but NOT agent axes (workspace/instance → PR-1b)" do
      out = Compose.materialize(role(), opts())

      assert Enum.all?(out.effective_caps, fn cap ->
               is_map(cap) and not is_struct(cap, Ezagent.Capability) and
                 Map.has_key?(cap, :behavior) and Map.has_key?(cap, :action) and
                 Map.has_key?(cap, :kind) and
                 not Map.has_key?(cap, :workspace_uri) and not Map.has_key?(cap, :instance)
             end)
    end

    test "FAIL-CLOSED on truthy non-boolean policy result (only strict true grants)" do
      out = Compose.materialize(role(), opts(authorize_cap: fn _ -> {:error, :nope} end))
      assert out.effective_caps == []
    end

    test "FAIL-CLOSED (no crash) when the policy predicate RAISES" do
      out = Compose.materialize(role(), opts(authorize_cap: fn _ -> raise "boom" end))
      assert out.effective_caps == []
    end
  end
end
