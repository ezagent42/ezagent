defmodule Ezagent.Behavior.Workspace.AgentCreateSoulTest do
  @moduledoc """
  Focused unit tests for B1: `coerce_create_args/1` accepts optional `:soul`.

  Tests are at the dispatch facade level because `coerce_create_args/1` is
  private. We exercise the soul-related paths by:

  1. Rejecting a non-string non-nil soul (`{:error, {:bad_soul, _}}`).
  2. Accepting a nil soul (no rejection at coerce stage — later validation fires
     for the echo flavor missing nothing else).
  3. Accepting a string soul — the value threads through to `do_create_agent`
     (proven by absence of `:bad_soul` error + reaching a LATER validation
     failure such as the echo without-PTY cwd path or the direct-spawn call).

  String-key variant is also covered (LV passes string keys).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User

  setup do
    ws_name = "soul-test-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    }

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  describe "coerce_create_args/1 — soul validation" do
    test "non-string non-nil soul is rejected with {:bad_soul, _}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, {:bad_soul, 42}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "echo", name: "x", cwd: "", with_pty: false, soul: 42},
                 admin_ctx
               )
    end

    test "list soul is rejected with {:bad_soul, _}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, {:bad_soul, ["bad"]}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "echo",
                   name: "x",
                   cwd: "",
                   with_pty: false,
                   soul: ["bad"]
                 },
                 admin_ctx
               )
    end

    test "nil soul is accepted (no :bad_soul error, reaches later validation)", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      # echo without PTY and empty cwd is valid; reaches do_create_agent.
      # We don't have a live Template Class, so the result will be a
      # template-registration or spawn error — NOT {:error, {:bad_soul, _}}.
      result =
        Workspace.create_agent(
          workspace_uri,
          %{flavor: "echo", name: "soul-nil", cwd: "", with_pty: false, soul: nil},
          admin_ctx
        )

      # Must NOT be a soul rejection.
      refute match?({:error, {:bad_soul, _}}, result)
    end

    test "string soul is accepted and threaded through (no :bad_soul error)", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      # Provide a string soul — coerce must accept it. echo without PTY +
      # empty cwd is a valid path that reaches do_create_agent.
      result =
        Workspace.create_agent(
          workspace_uri,
          %{
            flavor: "echo",
            name: "soul-string",
            cwd: "",
            with_pty: false,
            soul: "你是导购"
          },
          admin_ctx
        )

      # Must NOT be a soul rejection.
      refute match?({:error, {:bad_soul, _}}, result),
             "string soul should be accepted by coerce_create_args; got: #{inspect(result)}"
    end

    test "string-key soul (LV path) is accepted", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      result =
        Workspace.create_agent(
          workspace_uri,
          %{
            "flavor" => "echo",
            "name" => "soul-strkey",
            "cwd" => "",
            "with_pty" => false,
            "soul" => "LV soul"
          },
          admin_ctx
        )

      refute match?({:error, {:bad_soul, _}}, result),
             "string-keyed soul should be accepted; got: #{inspect(result)}"
    end

    test "atom-key soul takes precedence over string-key soul when atom value is invalid", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      # Mixed map — atom key wins over string key.
      # Non-string atom-key value must be rejected.
      mixed =
        Map.merge(%{flavor: "echo", name: "x", cwd: "", with_pty: false, soul: 99}, %{
          "soul" => "string fallback"
        })

      result =
        Workspace.create_agent(
          workspace_uri,
          mixed,
          admin_ctx
        )

      assert {:error, {:bad_soul, 99}} = result
    end
  end

  describe "coerce_create_args/1 — with_pty falsy-override regression (B1 fix)" do
    test "explicit atom-key with_pty: false is NOT overridden by string-key 'with_pty' => true",
         %{
           workspace_uri: workspace_uri,
           admin_ctx: admin_ctx
         } do
      # Before the fix: `Map.get(args, :with_pty) || Map.get(args, "with_pty") || false`
      # would evaluate `false || true` and return `true`, silently overriding the
      # explicit atom-key `false`. After the fix with `Map.get/3`, the atom key is
      # present so it wins as `false`, and we never touch the string key.
      #
      # echo + with_pty: true requires a non-empty cwd; echo + with_pty: false +
      # empty cwd is valid. So if `with_pty` were incorrectly coerced to `true`,
      # we would get {:error, :cwd_required_for_echo_with_pty}. If it stays `false`,
      # we pass cwd validation and reach do_create_agent (failing for a different
      # reason, e.g. spawn/template).
      mixed_args =
        Map.merge(
          %{
            flavor: "echo",
            name: "pty-override-#{System.unique_integer([:positive])}",
            cwd: "",
            with_pty: false
          },
          %{
            "with_pty" => true
          }
        )

      result = Workspace.create_agent(workspace_uri, mixed_args, admin_ctx)

      # The old `||` bug produces :cwd_required_for_echo_with_pty because it
      # coerced `false || true == true`, then cwd="" fails the pty cwd check.
      refute match?({:error, :cwd_required_for_echo_with_pty}, result),
             "with_pty: false must NOT be overridden by string-key 'with_pty' => true; got: #{inspect(result)}"
    end

    test "explicit atom-key cwd: '' is NOT overridden by string-key 'cwd' => '/tmp'", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      # Before the fix: `Map.get(args, :cwd) || Map.get(args, "cwd") || ""`
      # would evaluate `"" || "/tmp"` and return "/tmp", silently overriding the
      # explicit atom-key `""`. With `Map.get/3`, the atom key is present and
      # wins as "".
      #
      # cc requires a non-empty cwd; if atom-key "" is incorrectly overridden by
      # string-key "/tmp" (a real dir), we'd proceed past cwd validation. With the
      # fix, we expect :cwd_required_for_cc (empty string cwd rejects for cc).
      mixed_args =
        Map.merge(
          %{
            flavor: "cc",
            name: "cwd-override-#{System.unique_integer([:positive])}",
            cwd: "",
            with_pty: false
          },
          %{
            "cwd" => "/tmp"
          }
        )

      result = Workspace.create_agent(workspace_uri, mixed_args, admin_ctx)

      assert {:error, :cwd_required_for_cc} = result,
             "atom-key cwd: '' must NOT be overridden by string-key 'cwd' => '/tmp'; got: #{inspect(result)}"
    end
  end
end
