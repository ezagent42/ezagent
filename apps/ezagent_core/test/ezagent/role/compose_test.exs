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

  describe "materialize/2" do
    test "composes role behaviors with the flavor's behaviors (union, deduped)" do
      out =
        Compose.materialize(role(), %{
          flavor_behaviors: [Ezagent.Behavior.Identity, Ezagent.Behavior.Sandbox],
          authorize_cap: fn _ -> true end
        })

      # role's [Sandbox] ∪ flavor's [Identity, Sandbox], deduped
      assert Enum.sort(out.behaviors) ==
               Enum.sort([Ezagent.Behavior.Sandbox, Ezagent.Behavior.Identity])
    end

    test "sandbox CONTENTS are flavor-independent (same role → same content)" do
      cc =
        Compose.materialize(role(), %{flavor_behaviors: [:cc_b], authorize_cap: fn _ -> true end})

      codex =
        Compose.materialize(role(), %{
          flavor_behaviors: [:codex_b],
          authorize_cap: fn _ -> true end
        })

      assert cc.sandbox_content == codex.sandbox_content
      assert cc.sandbox_content == %{skills: ["orchestrator"], plugins: ["np"], prompt: "persona"}
    end

    test "FAIL-CLOSED: a requested cap the policy rejects is NOT in effective_caps" do
      # policy permits :send but NOT :drive (e.g. a no-bridge flavor)
      authorize = fn %{action: action} -> action == :send end

      out = Compose.materialize(role(), %{flavor_behaviors: [], authorize_cap: authorize})

      assert out.effective_caps == [%{behavior: Ezagent.Behavior.Chat, action: :send}]
      refute Enum.any?(out.effective_caps, &(&1.action == :drive))
    end

    test "all-permitted policy yields effective == requested" do
      out = Compose.materialize(role(), %{flavor_behaviors: [], authorize_cap: fn _ -> true end})
      assert out.effective_caps == role().requested_caps
    end

    test "canonicalizes a realistic persisted JSON cap (string keys + values) so an atom-value predicate matches" do
      # the realistic persisted shape: string keys AND string values. Compose
      # canonicalizes behavior→module + action→atom, so an atom/module-value
      # policy predicate matches and effective_caps are value-canonical (PR-1b
      # then injects the workspace + mints via Capability.normalize!).
      {:ok, role} =
        Role.new(%{
          "requested_caps" => [%{"behavior" => "Ezagent.Behavior.Sandbox", "action" => "read"}]
        })

      authorize = fn %{action: :read} -> true end

      out = Compose.materialize(role, %{flavor_behaviors: [], authorize_cap: authorize})

      assert out.effective_caps == [%{behavior: Ezagent.Behavior.Sandbox, action: :read}]
    end

    test "an unresolvable behavior value stays a string → policy rejects it (fail-closed, no phantom atom)" do
      {:ok, role} =
        Role.new(%{"requested_caps" => [%{"behavior" => "No.Such.Module", "action" => "read"}]})

      # atom/module-value predicate; the unresolved string behavior fails it
      authorize = fn %{behavior: b} -> is_atom(b) end

      out = Compose.materialize(role, %{flavor_behaviors: [], authorize_cap: authorize})

      assert out.effective_caps == []
    end

    test "FAIL-CLOSED (no crash) when the policy predicate RAISES" do
      # a mis-integrated / total-violating predicate must not crash
      # materialization — the boundary catches the raise and drops the cap.
      raising = fn _ -> raise "boom" end

      out = Compose.materialize(role(), %{flavor_behaviors: [], authorize_cap: raising})
      assert out.effective_caps == []
    end

    test "effective_caps are authorized REQUEST TEMPLATES (no workspace_uri — injected at materialization)" do
      # A role is workspace-agnostic; the request template carries authority axes
      # (behavior/action) but NOT workspace_uri. PR-1b injects the agent's
      # workspace + mints via Capability.normalize!. This pins that contract so
      # nobody mistakes effective_caps for mint-ready %Capability{} structs.
      out = Compose.materialize(role(), %{flavor_behaviors: [], authorize_cap: fn _ -> true end})

      assert Enum.all?(out.effective_caps, fn cap ->
               is_map(cap) and not is_struct(cap, Ezagent.Capability) and
                 not Map.has_key?(cap, :workspace_uri) and Map.has_key?(cap, :behavior) and
                 Map.has_key?(cap, :action)
             end)
    end

    test "FAIL-CLOSED on truthy non-boolean policy result (only strict true grants)" do
      # a mis-integrated policy that returns a truthy non-`true` value (e.g.
      # `{:error, :not_permitted}`) must NOT authorize the cap.
      out =
        Compose.materialize(role(), %{
          flavor_behaviors: [],
          authorize_cap: fn _ -> {:error, :not_permitted} end
        })

      assert out.effective_caps == []
    end
  end
end
