defmodule Ezagent.Agent.DefaultRecipeSeedTest do
  @moduledoc """
  `Ezagent.Agent.DefaultRecipeSeed` — the generic boot-time seeder for the
  cc-headless default agents `pm-coordinator` + `dev-together` (Phase 3 ③
  refactor 2026-06-30). Absorbs the template-seed mechanism assertions from the
  old `EzagentPluginKanban.PmCoordinatorSeedTest` / `DevTogetherSeedTest`.

  `seed_all/0` is `:test`-skipped (the boot DB write contends with the per-test
  Ecto sandbox), so the actual seed is driven via `do_seed_all/0` inside the
  test's own sandbox — the same discipline as `RecipeRegistry` / the identity
  admin-seed tests.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.{DefaultRecipeSeed, Recipe, RecipeRegistry}

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)
    :ok
  end

  describe ":test skip — seed_all/0 is a no-op in :test" do
    test "seed_all/0 returns :ok without writing (the boot path is sandbox-skipped)" do
      assert :ok = DefaultRecipeSeed.seed_all()
    end
  end

  describe "do_seed_all/0 (recipe-seed) + do_seed_templates_all/0 (template-seed) for both default agents" do
    test "do_seed_all/0 seeds both recipes into the read-through registry (flush → lookup resolves)" do
      assert :ok = DefaultRecipeSeed.do_seed_all()
      :ok = RecipeRegistry.flush_cache()

      assert {:ok, %Recipe{name: "pm-coordinator", skills: ["pm-coordinator"]}} =
               RecipeRegistry.lookup("pm-coordinator")

      assert {:ok, %Recipe{name: "dev-together", skills: ["dev-together"]}} =
               RecipeRegistry.lookup("dev-together")
    end

    test "do_seed_templates_all/0 seeds both `cc × <role>` AgentTemplates (KindRegistry hit)" do
      assert :ok = DefaultRecipeSeed.do_seed_templates_all()

      assert {:ok, _pid} =
               Ezagent.KindRegistry.lookup(
                 Ezagent.URI.template(:system, :agent, "pm-coordinator")
               )

      assert {:ok, _pid} =
               Ezagent.KindRegistry.lookup(Ezagent.URI.template(:system, :agent, "dev-together"))
    end

    test "idempotent — a second do_seed_all/0 + do_seed_templates_all/0 stay :ok" do
      assert :ok = DefaultRecipeSeed.do_seed_all()
      assert :ok = DefaultRecipeSeed.do_seed_all()
      assert :ok = DefaultRecipeSeed.do_seed_templates_all()
      assert :ok = DefaultRecipeSeed.do_seed_templates_all()
    end
  end

  describe "boot-safe — a pre-existing divergent recipe body does NOT crash" do
    test "do_seed_all/0 still returns :ok when a role was already seeded with a different body" do
      # Pre-seed pm-coordinator with a DIVERGENT body so the generic seeder's
      # seed_role_if_absent hits {:error, {:role_seed_collision, _}}. The seeder
      # must downgrade that to a warning + telemetry and still return :ok (an
      # after_boot-equivalent must never crash the boot).
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:ezagent, :agent, :default_recipe_seed, :"pm-coordinator", :recipe_seed_failed]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      {:ok, _} =
        RecipeRegistry.seed_role_if_absent(%{
          name: "pm-coordinator",
          passive: false,
          behaviors: [],
          skills: ["pm-coordinator"],
          requested_caps: [%{behavior: "Ezagent.Behavior.Kanban", action: :get_tree}]
        })

      assert :ok = DefaultRecipeSeed.do_seed_all()

      assert_received {[
                         :ezagent,
                         :agent,
                         :default_recipe_seed,
                         :"pm-coordinator",
                         :recipe_seed_failed
                       ], ^ref, %{count: 1}, _}
    end
  end
end
