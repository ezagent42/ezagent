defmodule Ezagent.Role.ComposeTest do
  use ExUnit.Case, async: true

  alias Ezagent.Role
  alias Ezagent.Role.Compose

  # Task #54 PR-1 §2.3 — the context-free half of materialization: the role
  # FILLS the sandbox (skills/plugins/prompt) and contributes behaviors; the
  # flavor contributes its per-instance behaviors. Sandbox CONTENTS are
  # flavor-independent (the §6 completion invariant). Cap authorization/minting
  # is NOT here — it needs full agent context and lives in the materialization
  # step (PR-1b).

  defp role do
    {:ok, role} =
      Role.new(%{
        skills: ["orchestrator"],
        plugins: ["np"],
        prompt: "persona",
        behaviors: [Ezagent.Behavior.Sandbox],
        requested_caps: [%{behavior: Ezagent.Behavior.Pty, action: :drive}]
      })

    role
  end

  describe "materialize/2" do
    test "composes role behaviors with the flavor's behaviors (union, deduped)" do
      out =
        Compose.materialize(role(), %{
          flavor_behaviors: [Ezagent.Behavior.Identity, Ezagent.Behavior.Sandbox]
        })

      assert Enum.sort(out.behaviors) ==
               Enum.sort([Ezagent.Behavior.Sandbox, Ezagent.Behavior.Identity])
    end

    test "sandbox CONTENTS are flavor-independent (same role → same content)" do
      cc = Compose.materialize(role(), %{flavor_behaviors: [:cc_b]})
      codex = Compose.materialize(role(), %{flavor_behaviors: [:codex_b]})

      assert cc.sandbox_content == codex.sandbox_content
      assert cc.sandbox_content == %{skills: ["orchestrator"], plugins: ["np"], prompt: "persona"}
    end

    test "does NOT emit caps (cap authorization/minting is the materialization step's job)" do
      out = Compose.materialize(role(), %{flavor_behaviors: []})
      refute Map.has_key?(out, :effective_caps)
      assert Map.keys(out) |> Enum.sort() == [:behaviors, :sandbox_content]
    end
  end
end
