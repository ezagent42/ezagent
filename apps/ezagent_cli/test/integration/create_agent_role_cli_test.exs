defmodule EzagentCli.Integration.CreateAgentRoleCLITest do
  @moduledoc """
  T1 (Phase 3 ③ 缺口1) — admin can create a `role × native` agent through the
  sanctioned operator CLI (`mix ezagent workspace create_agent --role <name>`).

  Two bugs were closed (forensic in the SPEC §缺口):

    1. the generic `:create_agent` action's interface did NOT declare `role`, so
       Optimus's `allow_unknown_args: false` parse gate REJECTED `--role` before
       it ever reached the handler — even though `AgentCreate.handle_create_agent/2`
       already reads `role` from args (RF-5a). Fixed by declaring
       `role: {:option, :string}` in the action schema.

    2. `TreeBuilder.action_subcommand/4` forced `required: true` on EVERY schema
       arg, and `Coercion.to_option/3`'s `Keyword.merge` let that win over the
       `{:option, _}` base's `required: false` — so the optional args (`--from`,
       `--flavor-config`, and now `--role`) were all wrongly REQUIRED at the parse
       gate. Fixed by deriving `required?` from the schema's `{:option, _}` marker.

  Test 1 pins the parse layer (the regression). Test 2 drives the full CLI
  parse → Dispatch path and proves the agent is really created with the role's
  minted caps (caps 真, read back from the Identity slice).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry, UriQuery}
  alias EzagentCli.{Dispatch, TreeBuilder}

  @flavor "t1-cli-native"
  @role_name "t1-cli-role"

  # Minimal inline role behavior (RoleTestBehavior is test-support in
  # ezagent_domain_workspace and not visible to this app's test compile).
  # It only needs to exist as a module the recipe can request a cap on.
  defmodule CliRoleBehavior do
    @moduledoc false
    use Ezagent.Lifecycle, state_slice: :t1_cli_role

    action(:ping,
      args: %{},
      returns: %{pong: :boolean},
      caps: [:ping],
      modes: [:call],
      description: "T1 CLI test role behavior"
    )

    def required_caps, do: %{ping: Ezagent.Capability.cap(:agent, __MODULE__, :ping)}

    def data_owner(%URI{} = uri), do: Ezagent.URI.instance(uri)
    def data_owner(:any), do: :any
    def data_owner(_), do: :no_owner

    @impl Ezagent.Lifecycle
    def create(_args), do: {:ok, %{pinged: false}}

    def handle_ping(_args, _ctx), do: {:ok, %{pong: true}, [{:set, :pinged, true}]}
  end

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    # CLI tests authenticate via the per-process caller override that
    # `EzagentCli.Exec.exec/2` sets in production after token auth.
    Process.put(
      :ezagent_cli_caller_override,
      {User.admin_uri(), MapSet.new([Ezagent.Capability.admin_genesis_cap()])}
    )

    :ok
  end

  describe "parse layer — generic create_agent accepts --role and respects optionality" do
    test "the create_agent subcommand exposes --role and marks optional args not-required" do
      spec = TreeBuilder.build()
      action = create_agent_subcommand(spec)
      assert action, "workspace.create_agent subcommand missing from the CLI tree"

      # Optimus normalizes options/flags to LISTS of structs keyed by long.
      required_by_long =
        action.options
        |> Map.new(fn o -> {o.long, o.required} end)

      flag_longs = action.flags |> Enum.map(& &1.long) |> MapSet.new()

      # The optional schema args must NOT be required at the parse gate.
      assert Map.fetch!(required_by_long, "--role") == false,
             "--role must be present and optional (bug 1 + bug 2)"

      assert Map.fetch!(required_by_long, "--from") == false,
             "--from is {:option, :uri} and must not be forced required (bug 2)"

      assert Map.fetch!(required_by_long, "--flavor-config") == false,
             "--flavor-config is {:option, :map} and must not be forced required (bug 2)"

      # The genuinely required args stay required.
      assert Map.fetch!(required_by_long, "--flavor") == true
      assert Map.fetch!(required_by_long, "--name") == true

      # The boolean `with_pty` arg is a presence FLAG, not a required
      # valued option (bug 3).
      assert MapSet.member?(flag_longs, "--with-pty"),
             "--with-pty must be a presence flag, not a required valued option"

      refute Map.has_key?(required_by_long, "--with-pty")
    end

    test "Optimus.parse accepts --role without the other optional args and carries it through" do
      spec = TreeBuilder.build()

      argv = [
        "workspace",
        "create_agent",
        "--workspace",
        "some-ws",
        "--flavor",
        "cc",
        "--name",
        "agent-x",
        "--cwd",
        "",
        "--role",
        "kanban-manager"
      ]

      assert {:ok, [:workspace, :create_agent], parsed} = Optimus.parse(spec, argv),
             "the parse gate rejected --role (or demanded --from/--flavor-config)"

      assert parsed.options.role == "kanban-manager"
      assert parsed.options.flavor == "cc"
      assert parsed.options.name == "agent-x"
    end
  end

  describe "e2e — admin creates role × native agent via the CLI parse → dispatch path" do
    setup do
      :ok =
        AgentFlavorRegistry.register(%{
          flavor: @flavor,
          kind: Ezagent.Entity.Agent,
          template_class: nil,
          cap_policy: &cap_policy/1
        })

      {:ok, _} =
        RecipeRegistry.seed_role_if_absent(%{
          name: @role_name,
          passive: true,
          behaviors: [CliRoleBehavior],
          requested_caps: [%{behavior: CliRoleBehavior, action: :ping}]
        })

      RecipeRegistry.flush_cache()
      :ok
    end

    test "agent is created and carries the role's minted cap (caps 真)" do
      skip_if_no_entity_spawn(fn ->
        ws_name = "t1-cli-#{System.unique_integer([:positive])}"
        {:ok, _ws_pid} = Ezagent.Workspace.create(ws_name, %{})
        name = "t1-agent-#{System.unique_integer([:positive])}"

        spec = TreeBuilder.build()

        argv = [
          "workspace",
          "create_agent",
          "--workspace",
          ws_name,
          "--flavor",
          @flavor,
          "--name",
          name,
          "--cwd",
          "",
          "--role",
          @role_name
        ]

        # Real parse gate — proves --role survives Optimus.
        assert {:ok, [:workspace, :create_agent], parsed} = Optimus.parse(spec, argv)
        assert parsed.options.role == @role_name

        # Real dispatch — the same code path `EzagentCli.Exec` drives after auth.
        assert {:ok, %{agent_uri: agent_uri}} =
                 Dispatch.run_action(
                   Ezagent.Entity.Workspace,
                   Ezagent.Behavior.Workspace,
                   :create_agent,
                   parsed
                 )

        assert agent_uri == Ezagent.URI.agent(ws_name, name)
        assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri)

        # The role was actually applied: its durable `passive` marker is set.
        assert {:ok, true} = UriQuery.resolve(:passive, agent_uri)

        # caps 真 — the recipe's requested cap was minted onto the agent's
        # Identity slice (fail-closed via the flavor cap-policy).
        held = Ezagent.Identity.list_caps_for(agent_uri)

        ping_caps =
          Enum.filter(held, fn c ->
            c.behavior == CliRoleBehavior and c.action == :ping
          end)

        assert length(ping_caps) == 1,
               "expected the recipe's minted {CliRoleBehavior, :ping} cap, got: " <>
                 inspect(Enum.to_list(held))
      end)
    end
  end

  # Fail-closed cap policy: grant exactly the recipe's {behavior, action} pairs.
  defp cap_policy(requested_caps) do
    allowed =
      requested_caps
      |> Enum.map(fn c -> {Map.get(c, :behavior), Map.get(c, :action)} end)
      |> MapSet.new()

    fn needed ->
      MapSet.member?(allowed, {Map.get(needed, :behavior), Map.get(needed, :action)})
    end
  end

  defp create_agent_subcommand(spec) do
    with ws when not is_nil(ws) <-
           Enum.find(spec.subcommands, fn s -> s.name == "workspace" end) do
      Enum.find(ws.subcommands, fn s -> s.name == "create_agent" end)
    end
  end

  defp skip_if_no_entity_spawn(body) do
    if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
         "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
      IO.puts(:stderr, "SKIP: entity spawn fn not registered (test bootstrap incomplete)")
      :ok
    else
      body.()
    end
  end
end
