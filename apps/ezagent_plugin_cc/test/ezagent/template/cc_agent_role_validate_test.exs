defmodule Ezagent.PluginCc.Template.CcAgentRoleValidateTest do
  @moduledoc """
  Phase 3 ③ T4 — `CcAgent.validate/1`'s `check_role` gate, GENERALIZED from the
  hardcoded `default`/`orchestrator` allowlist to "accept ANY registered role".

  Before T4 a cc template with `role: "pm-coordinator"` (or any name other than
  the two built-ins) was rejected `{:invalid_role, _}` at validate — so it never
  reached the (T2-generalized) `OrchestratorBootstrap` skill-install. This suite
  pins the new contract:

    * a REGISTERED role (any name) now passes validate (the T4 change — old code
      rejected it → red);
    * `default` / `orchestrator` (string + atom) STILL pass, via the pure
      fast-path (行为不变, no registry/DB needed);
    * an UNREGISTERED role still fails loud `{:invalid_role, name}`.

  role-as-data: a non-built-in role resolves read-through over ConfigStore
  (`RecipeRegistry.lookup/1`), so the suite needs the Ecto sandbox; boot's DB role
  seed is skipped in `:test`, so we seed an arbitrary role explicitly in setup
  inside the sandbox (matching `OrchestratorRoleTest`).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.PluginCc.Template.CcAgent

  # An arbitrary registered role name — the gate is GENERIC over any registered
  # role (机制 ≠ 业务). We use the real pm coordinator name to also document the
  # T4 → T6 path, but check_role only cares that the name resolves in the
  # registry; the recipe contents are irrelevant to validate.
  @registered_role "pm-coordinator"

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)

    # Seed a minimal valid role recipe so RecipeRegistry.lookup/1 resolves it.
    # Flush the ETS cache first so a prior test's cached entry can't mask state.
    :ok = RecipeRegistry.flush_cache()

    case RecipeRegistry.seed_role_if_absent(%{
           name: @registered_role,
           behaviors: [],
           requested_caps: [],
           skills: ["pm-coordinator"]
         }) do
      {:ok, _} -> :ok
      {:error, {:role_seed_collision, _}} -> :ok
    end

    :ok
  end

  defp tmpl(role) do
    base = %{
      "class" => "cc.agent",
      "agent_uri" => "entity://system/agent/cc_t4-#{System.unique_integer([:positive])}",
      "cwd" => System.tmp_dir!()
    }

    case role do
      :__omit__ -> base
      r -> Map.put(base, "role", r)
    end
  end

  describe "check_role generalization (T4)" do
    test "accepts a REGISTERED non-built-in role (the T4 change; old code rejected it)" do
      assert :ok = CcAgent.validate(tmpl(@registered_role))
    end

    test "still accepts role=\"default\" / :default (no-role special case, no registry)" do
      assert :ok = CcAgent.validate(tmpl("default"))
      assert :ok = CcAgent.validate(tmpl(:default))
    end

    test "still accepts role=\"orchestrator\" / :orchestrator (built-in fast-path)" do
      assert :ok = CcAgent.validate(tmpl("orchestrator"))
      assert :ok = CcAgent.validate(tmpl(:orchestrator))
    end

    test "accepts a template that omits the role field cleanly" do
      assert :ok = CcAgent.validate(tmpl(:__omit__))
    end

    test "rejects an UNREGISTERED role fail-loud {:invalid_role, name}" do
      assert {:error, {:invalid_role, "no-such-role"}} =
               CcAgent.validate(tmpl("no-such-role"))
    end

    test "rejects a non-string/non-atom role value fail-loud" do
      assert {:error, {:invalid_role, 123}} = CcAgent.validate(tmpl(123))
    end
  end
end
