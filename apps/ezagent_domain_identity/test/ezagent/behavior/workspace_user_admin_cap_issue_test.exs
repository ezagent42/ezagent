defmodule Ezagent.ActionSet.WorkspaceUserAdminCapIssueTest do
  @moduledoc """
  `create_user` is not a cap-minting oracle.

  It used to parse ARBITRARY caller-supplied cap text, stamp it
  `granted_by: admin` regardless of who was actually calling, and write it
  straight into `users.caps_json` — never touching `Ezagent.Cap.issue/3`, so
  `CapabilityRegistry.authorize_grant/3` never ran. A holder of
  `workspace_user_admin.create_user` (a WORKSPACE admin, not necessarily a
  global one) could therefore conjure a user holding any capability at all:

    * `"*"` — the full wildcard, i.e. **a second global admin**
    * `"agent.manage@<someone else's agent>"` — which, since Decision #163
      ("the terminal belongs to the creator"), carries that agent's PTY:
      arbitrary command execution inside its sandbox

  Codex PR #356 r1 narrowed WHO can reach this action (it split `:create_user`
  onto its own Behavior so a `Behavior.Workspace` cap no longer implies it).
  That fixed the door. It did not disarm the room. These tests pin the
  disarming: **what you may hand out is bounded by what you actually hold.**

  The workspace admin here **durably holds** the `create_user` cap — the
  refusals below are therefore about the authority they lack, not about having
  no authority at all.

  Remove the `Cap.issue/3` chokepoint from `handle_create_user/2` and the
  escalation tests go green. That is the bug.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.Workspace

  setup do
    ws_name = "capissue-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Workspace.create(ws_name, %{})
    ws = URI.new!("workspace://#{ws_name}")

    ws_admin = Ezagent.URI.new!("entity://#{ws_name}/user/ws-admin")

    # The workspace admin DURABLY holds exactly one cap: the right to call
    # create_user. Nothing else. This is the whole threat model.
    {:ok, _} =
      Ezagent.Users.create(ws_admin, nil, [
        %Ezagent.Capability{
          kind: :workspace,
          behavior: Ezagent.ActionSet.WorkspaceUserAdmin,
          action: :create_user,
          instance: ws,
          workspace_uri: ws,
          granted_by: User.admin_uri(),
          granted_at: DateTime.utc_now()
        }
      ])

    # `Cap.issue({:held_by, _})` loads the granter's DURABLE authority through
    # `Ezagent.Identity` (the configured `authority_loader`), which reads the
    # user's KIND slice — so the Kind has to be alive or the ws-admin looks
    # cap-less and the refusals below would prove nothing.
    {:ok, _} = Ezagent.SpawnRegistry.spawn(ws_admin)

    held = Ezagent.Identity.list_caps_for(ws_admin)

    # The threat model, pinned: they DO hold create_user, and they hold NO
    # admin authority. (`Users.create/3` also prepends the User Kind's
    # structural default caps — self-introspection — hence not exactly one.)
    assert Enum.any?(held, &(&1.behavior == Ezagent.ActionSet.WorkspaceUserAdmin)),
           "fixture: the ws-admin must durably hold create_user"

    refute Enum.any?(held, &(&1.kind == :any and &1.behavior == :any)),
           "fixture: the ws-admin must NOT hold admin authority"

    ws_admin_ctx = %{caller: ws_admin, caps: held}

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    }

    {:ok, ws_name: ws_name, ws: ws, ws_admin_ctx: ws_admin_ctx, admin_ctx: admin_ctx}
  end

  defp create_user(ws, ctx, ws_name, name, caps_str) do
    Workspace.create_user(
      ws,
      %{
        user_uri: "entity://#{ws_name}/user/#{name}",
        password: "correct-horse-battery-staple",
        caps: caps_str
      },
      ctx
    )
  end

  defp caps_of(ws_name, name) do
    uri = Ezagent.URI.new!("entity://#{ws_name}/user/#{name}")
    _ = Ezagent.SpawnRegistry.spawn(uri)
    Ezagent.Identity.list_caps_for(uri)
  end

  # The right assertion for a refused create is "the user was never created" —
  # NOT "the user holds no caps". Spawning a User Kind for a URI with no row
  # still yields the Kind's STRUCTURAL default caps (self-introspection), so a
  # cap-count assertion would be measuring the wrong thing.
  defp refute_user_exists(ws_name, name) do
    uri = Ezagent.URI.new!("entity://#{ws_name}/user/#{name}")
    refute Ezagent.Users.get_by_uri(uri), "the create must have been aborted — no user row"
  end

  describe "a workspace admin cannot hand out authority they do not hold" do
    test "minting a FULL WILDCARD (i.e. a second global admin) is refused", ctx do
      assert {:error, {:cap_grant_refused, _cap, :wildcard_action_grant_requires_admin_authority}} =
               create_user(ctx.ws, ctx.ws_admin_ctx, ctx.ws_name, "esc-wild", "*")

      refute_user_exists(ctx.ws_name, "esc-wild")
    end

    test "minting OWNERSHIP of an agent is refused", ctx do
      # Decision #163: an agent's Manage cap carries its PTY, and PTY write is
      # arbitrary command execution in that agent's sandbox.
      victim = "entity://#{ctx.ws_name}/agent/cc_victim"

      assert {:error, {:cap_grant_refused, _cap, _reason}} =
               create_user(
                 ctx.ws,
                 ctx.ws_admin_ctx,
                 ctx.ws_name,
                 "esc-agent",
                 "agent.manage@#{victim}"
               )

      refute_user_exists(ctx.ws_name, "esc-agent")
    end

    test "one refused cap aborts the WHOLE create — no partially-capped user", ctx do
      assert {:error, {:cap_grant_refused, _, _}} =
               create_user(ctx.ws, ctx.ws_admin_ctx, ctx.ws_name, "esc-mixed", "workspace.read,*")

      # All-or-nothing: `workspace.read` was grantable, `*` was not.
      refute_user_exists(ctx.ws_name, "esc-mixed")
    end

    test "creating a user with NO caps still works — the action is not broken", ctx do
      assert {:ok, %{caps_granted: 0}} =
               create_user(ctx.ws, ctx.ws_admin_ctx, ctx.ws_name, "plain", "")
    end
  end

  describe "admin retains full authority" do
    test "admin may still mint a wildcard", ctx do
      assert {:ok, %{caps_granted: 1}} =
               create_user(ctx.ws, ctx.admin_ctx, ctx.ws_name, "admin-minted", "*")

      assert Enum.any?(
               caps_of(ctx.ws_name, "admin-minted"),
               &(&1.kind == :any and &1.behavior == :any)
             ),
             "admin's wildcard grant must land"
    end
  end

  describe "provenance is accountable" do
    test "granted_by is the ACTUAL caller, not a laundered admin", ctx do
      # The old code stamped `granted_by: admin_uri()` no matter who called, so
      # the audit trail lied about who handed the authority out.
      assert {:ok, %{caps_granted: 1}} =
               create_user(ctx.ws, ctx.admin_ctx, ctx.ws_name, "prov", "workspace.read")

      granted =
        ctx.ws_name
        |> caps_of("prov")
        |> Enum.find(&(&1.behavior == Ezagent.ActionSet.Workspace))

      assert %Ezagent.Capability{granted_by: granter} = granted
      assert granter == User.admin_uri()
    end
  end
end
