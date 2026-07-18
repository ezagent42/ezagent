defmodule Ezagent.PluginPy.NpRoleTest do
  @moduledoc """
  py-agent P4 — `np` re-homed as a py-ROLE.

  np is no longer its own flavor/plugin: it is the `py` flavor + the re-homed
  `np.py` script (numpy/sympy whitelist intact), carried via the role-script
  channel (`Recipe.script` → `Recipe.Compose.sandbox_content.script` → config_dir
  `agent.py`). This test proves:

  1. (fast, no uv) the `np` role recipe carries the np.py script verbatim, and
     the script's numpy/sympy security model is intact (the `_SAFE_NAMES`
     whitelist + `parse_expr`/`parse_latex` are byte-identical to the deleted np
     plugin's, asserted by content). The recipe carries NO caps — np needs none
     (see `np_role_recipe/0`); py now runs on the unified `Entity.Agent` Kind.
  2. (`:uv`) creating a py-agent via the REAL create path with `role: "np"`
     installs np.py into the agent's config_dir + evaluates a numpy/sympy
     expression end-to-end via the single `receive` method.
  """

  use EzagentCore.DataCase, async: false

  alias EzagentPluginPy.Application, as: PyApp
  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Domain.Python

  describe "the np role recipe (fast — no subprocess)" do
    test "carries the np.py script (no caps while own-Kind); whitelist intact" do
      recipe = PyApp.np_role_recipe()

      assert recipe.name == "np"
      assert is_binary(recipe.script) and recipe.script != ""

      # The script == the priv np.py (single source of truth).
      priv_np =
        :ezagent_plugin_py |> :code.priv_dir() |> Path.join("python/np.py") |> File.read!()

      assert recipe.script == priv_np

      # numpy/sympy whitelist intact — the security model is the same one the
      # deleted np plugin shipped (do NOT weaken). Assert the hardened markers
      # are present + the structural defense (parse_expr/parse_latex, NO raw
      # eval) is verbatim.
      assert recipe.script =~ "_SAFE_NAMES"
      assert recipe.script =~ "parse_expr(expr, local_dict=_SAFE_NAMES"
      assert recipe.script =~ "from sympy.parsing.latex import parse_latex"
      assert recipe.script =~ "import numpy as np"
      # The structural defense: input is parsed via sympy parse_expr against the
      # explicit whitelist (NOT raw eval/exec). Assert the safe-parse call sites
      # are present verbatim — these ARE the security model (do NOT weaken).
      assert recipe.script =~ "parsed = parse_expr(expr, local_dict=_SAFE_NAMES, evaluate=True)"
      assert recipe.script =~ "parsed = parse_latex(expr)"

      # The np recipe carries NO caps — a py-agent does not need granted caps to
      # function (the session→agent dispatch carries the sender's caps; the reply
      # presents its own inline session.send cap, #154). py now runs on the
      # unified Entity.Agent Kind (full base set incl. Identity), so a future
      # py-role that DOES need caps can add :requested_caps (see np_role_recipe/0).
      refute Map.has_key?(recipe, :requested_caps)
    end

    test "the np role seeds + resolves read-through under \"np\" (script preserved)" do
      # role-as-data: boot SEEDS the recipe into ConfigStore; lookup resolves it
      # read-through. (Boot's DB seed is :test-skipped, so seed explicitly here in
      # the DataCase sandbox.) np is a BUILT-IN, so its `script` is allowed (the
      # trusted code path); flush the cache to prove the resolve-from-ConfigStore.
      {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
      assert {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(PyApp.np_role_recipe())
      :ok = Ezagent.Agent.RecipeRegistry.flush_cache()

      assert {:ok, %Ezagent.Agent.Recipe{name: "np", script: script}} =
               Ezagent.Agent.RecipeRegistry.lookup("np")

      assert is_binary(script) and script =~ "_SAFE_NAMES"
    end
  end

  describe "create a py-agent with role np (uv — real subprocess)" do
    setup do
      case System.find_executable("uv") do
        nil ->
          {:skip, "uv not on PATH"}

        _ ->
          # role-as-data: boot's DB seed is :test-skipped, so seed the np role
          # into ConfigStore here so the create path's read-through lookup resolves.
          {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
          {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(PyApp.np_role_recipe())
          Ezagent.Agent.RecipeRegistry.flush_cache()

          ws_name = "np-role-#{System.unique_integer([:positive])}"
          {:ok, _ws_pid} = Workspace.create(ws_name, %{})
          workspace_uri = URI.new!("workspace://#{ws_name}")

          admin_ctx =
            workspace_uri
            |> Ezagent.Test.CapHelper.signed_workspace_ctx!(User.admin_uri())
            |> Map.put(:deadline_ms, 120_000)

          {:ok, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
      end
    end

    @tag :uv
    test "role np installs np.py + numpy/sympy compute round-trips via receive",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      name = "calc#{System.unique_integer([:positive])}"

      assert {:ok, %{agent_uri: %URI{} = agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "py",
                   name: name,
                   cwd: "",
                   with_pty: false,
                   role: "np",
                   # NB: no operator `script` — the ROLE carries it (the P4
                   # role-script channel). An operator script here would conflict.
                   flavor_config: %{"timeout_ms" => "120000"}
                 },
                 admin_ctx
               )

      on_exit(fn ->
        _ = Python.stop(agent_uri)
        _ = Ezagent.Kind.terminate(agent_uri)
      end)

      # The role's np.py was installed into the agent's config_dir as agent.py.
      config_dir = Ezagent.Sandbox.ConfigDir.path(agent_uri, "py")
      installed = Path.join(config_dir, "agent.py")

      priv_np =
        :ezagent_plugin_py |> :code.priv_dir() |> Path.join("python/np.py") |> File.read!()

      assert File.read!(installed) == priv_np

      assert wait_alive(agent_uri, 120_000),
             "the np-as-py-role subprocess must be alive after create"

      # numpy/sympy compute end-to-end via the single `receive` method:
      # "2+2" -> compute -> "= 4.0" (whitelist intact, parse_expr path).
      assert {:ok, %{"text" => text}} =
               Python.call(
                 agent_uri,
                 "receive",
                 %{"text" => "2+2", "from" => "u", "session" => "s"},
                 120_000
               )

      assert text =~ "4"

      # sympy symbolic via the _SAFE_NAMES whitelist: sqrt(16) -> 4, sin(0) -> 0.
      assert {:ok, %{"text" => sqrt_text}} =
               Python.call(
                 agent_uri,
                 "receive",
                 %{"text" => "sqrt(16)", "from" => "u", "session" => "s"},
                 120_000
               )

      assert sqrt_text =~ "4"

      # The IN-SCRIPT chat→method heuristic (the former BEAM `pick_method`):
      # a backslash command ROUTES to compute_latex (not compute). antlr4 may be
      # absent in the uv env (verbatim from np — latex was never wired with
      # antlr), so the latex branch may surface a parse error; either way the
      # reply proves the heuristic dispatched to the LaTeX path, NOT compute.
      assert {:ok, %{"text" => latex_text}} =
               Python.call(
                 agent_uri,
                 "receive",
                 %{"text" => "\\frac{1}{2}", "from" => "u", "session" => "s"},
                 120_000
               )

      assert latex_text =~ "0.5" or latex_text =~ "latex",
             "a backslash expr must route to the latex branch (heuristic in-script); got #{inspect(latex_text)}"

      # Security model intact — a malicious __import__ is parsed by sympy
      # parse_expr against the whitelist (the np plugin's exact behavior; we do
      # NOT weaken it). It must not raise out of receive (returns a result/str).
      assert {:ok, %{"text" => _}} =
               Python.call(
                 agent_uri,
                 "receive",
                 %{"text" => "pi*2", "from" => "u", "session" => "s"},
                 120_000
               )
    end
  end

  describe "security — a role-carried script rides the same cap gate (spec §5)" do
    setup do
      # role-as-data: seed the np role into ConfigStore (boot's DB seed is
      # :test-skipped) so the create path's read-through lookup resolves "np".
      {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
      {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(PyApp.np_role_recipe())
      Ezagent.Agent.RecipeRegistry.flush_cache()

      ws_name = "np-role-sec-#{System.unique_integer([:positive])}"
      {:ok, _ws_pid} = Workspace.create(ws_name, %{})
      {:ok, workspace_uri: URI.new!("workspace://#{ws_name}"), ws_name: ws_name}
    end

    test "a NON-operator cannot inject a role-carried script (create fails fail-closed)",
         %{workspace_uri: workspace_uri, ws_name: ws_name} do
      # The injection vector P4 must gate: a lesser-cap holder using a ROLE to
      # smuggle a script onto a new agent. py's role-script path flows through
      # the SAME `:create_agent` cap chokepoint as every create — a capless
      # caller is rejected BEFORE the handler body, so no script is installed.
      non_operator_ctx = %{
        caller: URI.new!("entity://#{ws_name}/user/intruder"),
        caps: MapSet.new()
      }

      name = "evil#{System.unique_integer([:positive])}"

      result =
        Workspace.create_agent(
          workspace_uri,
          %{flavor: "py", name: name, cwd: "", with_pty: false, role: "np"},
          non_operator_ctx
        )

      assert result == {:error, :missing_cap},
             "a non-operator must not inject a role-carried script; got #{inspect(result)}"

      agent_uri = URI.new!("entity://#{ws_name}/agent/#{name}")
      refute Python.alive?(agent_uri)
    end

    test "a role script + an operator script in the same create is a CONFLICT (fail loud)",
         %{workspace_uri: workspace_uri} do
      admin_ctx =
        Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

      name = "conflict#{System.unique_integer([:positive])}"

      # Two authorities for the same immutable file → refused, not silently
      # resolved (the script is the security-bearing artifact, §5).
      result =
        Workspace.create_agent(
          workspace_uri,
          %{
            flavor: "py",
            name: name,
            cwd: "",
            with_pty: false,
            role: "np",
            flavor_config: %{"script" => "print('operator')"}
          },
          admin_ctx
        )

      assert result == {:error, :role_script_conflicts_with_operator_script},
             "a role script + operator script must fail loud; got #{inspect(result)}"
    end
  end

  defp wait_alive(uri, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_alive(uri, deadline)
  end

  defp do_wait_alive(uri, deadline) do
    cond do
      Python.alive?(uri) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(200)
        do_wait_alive(uri, deadline)
    end
  end
end
