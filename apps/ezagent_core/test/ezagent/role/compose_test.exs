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
  #
  # NB: behavior modules used here must be loadable in ezagent_core's own test
  # context — `Ezagent.Behavior.Sandbox` is core; domain behaviors (Identity,
  # ApiKeys, …) are not loaded here.

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
        Compose.materialize(role(), %{flavor_behaviors: [Ezagent.Behavior.Sandbox, :flavor_b]})

      # role's [Sandbox] ∪ flavor's [Sandbox, :flavor_b], deduped
      assert Enum.sort(out.behaviors) == Enum.sort([Ezagent.Behavior.Sandbox, :flavor_b])
    end

    test "sandbox CONTENTS are flavor-independent (same role → same content)" do
      a = Compose.materialize(role(), %{flavor_behaviors: [:flavor_a]})
      b = Compose.materialize(role(), %{flavor_behaviors: [:flavor_b]})

      assert a.sandbox_content == b.sandbox_content
      assert a.sandbox_content == %{skills: ["orchestrator"], plugins: ["np"], prompt: "persona"}
    end

    test "does NOT emit caps (cap authorization/minting is the materialization step's job)" do
      out = Compose.materialize(role(), %{flavor_behaviors: []})
      refute Map.has_key?(out, :effective_caps)
      assert Map.keys(out) |> Enum.sort() == [:behaviors, :passive, :sandbox_content]
    end

    test "RF-6: threads the role's `passive` marker through to the materialized output" do
      # default (principal) role
      assert %{passive: false} = Compose.materialize(role(), %{flavor_behaviors: []})

      # a passive (non-principal data-actor) role carries passive: true through so
      # the create step (RF-5a) can record it as the stored agent attribute.
      {:ok, passive_role} = Role.new(%{skills: ["kanban"], passive: true})
      assert %{passive: true} = Compose.materialize(passive_role, %{flavor_behaviors: []})
    end
  end
end
