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
