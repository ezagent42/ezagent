defmodule EzagentCli.Integration.DispatchVerbTest do
  @moduledoc """
  Phase 3 ③ T7f — the generic `mix ezagent dispatch <uri> --action
  <behavior.action> [--args <json>]` verb.

  Why it exists: the kind/action CLI tree is derived from
  `BehaviorRegistry.list_all/0` (STATICALLY registered Behaviors). Per-instance
  role-mounted Behaviors (kanban/github, mounted via RF-1 on the generic
  `Entity.Agent` host, NOT statically registered) never appear as typed verbs,
  so `mix ezagent kanban.*` fails "unrecognized arguments". `dispatch` is the
  one generic verb reaching ANY mounted action by full URI + `?action=`.

  What this file pins:

    1. the `dispatch` subcommand is in the Optimus tree (with `target` arg +
       `--action`/`--args`);
    2. `run_dispatch/1` builds the canonical target (full URI + `?action=`),
       parses `--args` JSON, and surfaces clear errors for bad action / bad
       JSON / no identity;
    3. **CapBAC gate** through the FULL `EzagentCli.Exec.exec/2` path
       (token → authenticate → caller override → run_dispatch →
       Invocation.dispatch → CapBAC): an admin token dispatches a cap-gated
       action successfully; a least-priv (empty-caps) token is DENIED. This is
       the same authorization the typed verbs get — proven for the generic one.
  """

  use EzagentCore.DataCase, async: false

  alias EzagentCli.{Dispatch, Exec, TreeBuilder}
  alias Ezagent.Capability
  alias Ezagent.Entity.{Token, User}
  alias Ezagent.Users

  defp admin_override do
    Process.put(
      :ezagent_cli_caller_override,
      {User.admin_uri(), MapSet.new([Capability.admin_genesis_cap()])}
    )
  end

  describe "TreeBuilder.build/1 — dispatch subcommand shape" do
    test "exposes a top-level `dispatch` subcommand with target arg + action option" do
      spec = TreeBuilder.build()
      dispatch = Enum.find(spec.subcommands, fn s -> s.name == "dispatch" end)
      assert dispatch, "the generic `dispatch` verb must be a top-level subcommand"

      assert Enum.any?(dispatch.args, fn a -> to_string(a.name) == "target" end),
             "dispatch must take a positional <uri> target arg"

      option_names = Enum.map(dispatch.options, &to_string(&1.name))
      assert "action" in option_names, "dispatch must take --action <behavior.action>"
      assert "args" in option_names, "dispatch must take --args <json>"
    end
  end

  describe "Dispatch.run_dispatch/1 — target build + arg parse + errors" do
    setup do
      admin_override()
      :ok
    end

    test "full URI + --action reaches the target action (workspace.list_members)" do
      name = "disp-#{System.unique_integer([:positive])}"
      members = [User.admin_uri()]
      {:ok, _pid} = Ezagent.Workspace.create(name, %{members: members})

      parsed = %{
        args: %{target: "workspace://#{name}"},
        options: %{action: "workspace.list_members"},
        flags: %{}
      }

      assert {:ok, %{members: returned}} = Dispatch.run_dispatch(parsed)
      assert length(returned) == 1
    end

    test "--args JSON object is decoded + top-level keys atomized (existing atoms)" do
      name = "disp-args-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Ezagent.Workspace.create(name)

      member_uri = "entity://#{name}/agent/test_disp-new"

      parsed = %{
        args: %{target: "workspace://#{name}"},
        options: %{
          action: "workspace.add_member",
          args: Jason.encode!(%{member: member_uri})
        },
        flags: %{cast: true}
      }

      # add_member accepts the member (atomized :member key reached the handler);
      # a string-keyed %{"member" => _} would NOT match the handler head.
      assert {:ok, _} = Dispatch.run_dispatch(parsed)
    end

    test "action without a dot is rejected before dispatch" do
      parsed = %{
        args: %{target: "workspace://whatever"},
        options: %{action: "set_status"},
        flags: %{}
      }

      assert {:error, {:bad_action_format, "set_status"}} = Dispatch.run_dispatch(parsed)
    end

    test "malformed --args JSON is rejected" do
      parsed = %{
        args: %{target: "workspace://whatever"},
        options: %{action: "kanban.set_status", args: "{not json"},
        flags: %{}
      }

      assert {:error, {:malformed_args_json, _}} = Dispatch.run_dispatch(parsed)
    end

    test "non-object --args JSON is rejected" do
      parsed = %{
        args: %{target: "workspace://whatever"},
        options: %{action: "kanban.set_status", args: "[1,2,3]"},
        flags: %{}
      }

      assert {:error, {:args_not_a_json_object, _}} = Dispatch.run_dispatch(parsed)
    end

    test "missing target / missing action surface clear errors" do
      assert {:error, :missing_target_uri} =
               Dispatch.run_dispatch(%{args: %{}, options: %{action: "k.a"}, flags: %{}})

      assert {:error, :missing_action} =
               Dispatch.run_dispatch(%{
                 args: %{target: "workspace://x"},
                 options: %{},
                 flags: %{}
               })
    end
  end

  describe "Dispatch.run_dispatch/1 — no ambient identity (refuses)" do
    test "no token + no --as = no identity, REFUSE (never elevate to admin)" do
      Process.delete(:ezagent_cli_caller_override)

      parsed = %{
        args: %{target: "workspace://x"},
        options: %{action: "workspace.list_members"},
        flags: %{}
      }

      assert {:error, :no_identity} = Dispatch.run_dispatch(parsed)
    end
  end

  describe "CapBAC gate through the full Exec.exec/2 token path" do
    @describetag :umbrella_only

    test "cap-holding token dispatches a cap-gated action; least-priv token is DENIED" do
      name = "disp-cap-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Ezagent.Workspace.create(name, %{members: [User.admin_uri()]})

      target = "workspace://#{name}"

      # (a) a user HOLDING the workspace cap (same workspace as target) →
      #     list_members authorized through the FULL token path.
      ws_cap =
        Capability.cap(:workspace, Ezagent.Behavior.Workspace, :any)
        |> Map.put(:granted_by, User.admin_uri())
        |> Map.put(:granted_at, DateTime.utc_now())

      authz_uri_str = "entity://#{name}/user/authz_#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(authz_uri_str, nil, [ws_cap])
      authz_uri = Ezagent.URI.new!(authz_uri_str)
      {:ok, _} = Ezagent.SpawnRegistry.spawn(authz_uri)
      {authz_token, _} = Token.mint(authz_uri, label: "t7f-authz")

      authz_result =
        Exec.exec(
          ["dispatch", target, "--action", "workspace.list_members"],
          token: authz_token,
          entity_uri: authz_uri_str
        )

      assert authz_result.exit_code == 0,
             "cap-holding token must pass CapBAC for list_members. out=#{inspect(authz_result.output)}"

      # (b) least-priv user IN the same workspace, EMPTY caps → denied. Same
      #     workspace isolates the denial to the missing :list_members cap
      #     (not a cross-workspace rejection).
      lp_uri_str = "entity://#{name}/user/lp_#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(lp_uri_str, nil, [])
      lp_uri = Ezagent.URI.new!(lp_uri_str)
      {:ok, _lp_pid} = Ezagent.SpawnRegistry.spawn(lp_uri)
      {lp_token, _} = Token.mint(lp_uri, label: "t7f-leastpriv")

      lp_result =
        Exec.exec(
          ["dispatch", target, "--action", "workspace.list_members"],
          token: lp_token,
          entity_uri: lp_uri_str
        )

      assert lp_result.exit_code != 0,
             "least-priv (empty-caps) token escalated via the dispatch verb — " <>
               "CapBAC gate bypassed. out=#{inspect(lp_result.output)}"
    end
  end
end
