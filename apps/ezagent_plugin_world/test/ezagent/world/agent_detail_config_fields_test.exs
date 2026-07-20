defmodule Ezagent.World.AgentDetailConfigFieldsTest do
  @moduledoc """
  M1 regression gate: agent detail page exposes per-flavor config fields
  from both Config Cascade (soul_md) and Template Data (respawn_template_data).

  Anti-stub: the test creates a real agent, reads the detail state, and
  asserts config_fields array is present with the correct per-flavor keys.
  If IdentityData silently drops a field that exists in respawn_template_data,
  this test FAILS.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.World.IdentityData

  # A minimal VALID ezagent_python operator script (must call run() so the
  # subprocess stays alive — a bare `print(...)` exits at init).
  @py_script """
  import os, sys
  sys.path.insert(0, os.environ["EZAGENT_PYTHON_LIB_DIR"])
  from ezagent_python import method, run


  @method("receive")
  def receive(params):
      return {"text": params.get("text", "")}


  if __name__ == "__main__":
      run()
  """

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    assert "entity" in Ezagent.SpawnRegistry.registered_schemes()

    ws_name = "world-config-fields-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  describe "agent detail config_fields" do
    @tag :integration
    test "curl agent detail returns config_fields with model/provider/api_url from template data",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      agent_name = "curl-cfg-#{System.unique_integer([:positive])}"

      assert {:ok, %{agent_uri: agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "curl", name: agent_name, cwd: "", with_pty: false},
                 admin_ctx
               )

      agent_uri_str = URI.to_string(agent_uri)

      detail_state =
        IdentityData.state_for(
          %{
            component: "agent_detail",
            title: "Agent detail",
            path: "/identities/agents/#{URI.encode_www_form(agent_uri_str)}",
            entity_uri: agent_uri
          },
          %{
            workspace_uri: workspace_uri,
            caller_uri: User.admin_uri(),
            caller_caps: admin_ctx.caps
          }
        )

      # M1: config_fields must be present
      config_fields = detail_state["config_fields"]

      assert is_list(config_fields),
             "config_fields must be a list in agent_detail state (got: #{inspect(config_fields)})"

      refute config_fields == [],
             "config_fields must not be empty for a created curl agent"

      # Verify known curl fields appear (values may be null for direct-spawn)
      field_keys = Enum.map(config_fields, & &1["key"]) |> MapSet.new()

      assert MapSet.subset?(MapSet.new(["model", "provider", "api_url"]), field_keys),
             "curl agent config_fields must include model/provider/api_url; got: #{inspect(field_keys)}"

      # Verify each field has key, value key, source
      for field <- config_fields do
        assert is_binary(field["key"]), "config_field key must be a string"
        assert Map.has_key?(field, "value"), "config_field must have value key"

        assert field["source"] in ["template", "cascade", "runtime"],
               "config_field source must be template|cascade|runtime; got: #{inspect(field["source"])}"
      end

      # Direct-spawn curl agents have no respawn_template_data, so values are nil
      template_fields = Enum.filter(config_fields, &(&1["source"] == "template"))

      for field <- template_fields do
        assert field["key"] != nil, "template field key must be present even for direct-spawn"
      end

      # F5: the cap rows' `instance` must be a readable string, never a raw
      # `%URI{...}` / struct dump (`inspect(cap.instance)`).
      granted_caps = detail_state["granted_caps"]

      if is_list(granted_caps) do
        for cap <- granted_caps do
          instance = cap["instance"]

          assert is_binary(instance),
                 "cap instance must render as a string, got: #{inspect(instance)}"

          refute instance =~ "%URI{", "cap instance must not dump a raw URI struct: #{instance}"
          refute instance =~ "%Ezagent", "cap instance must not dump a raw struct: #{instance}"
        end
      end
    end

    @tag :integration
    @tag :uv
    test "py agent detail returns config_fields with its template fields (script/timeout_ms)",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      if System.find_executable("uv") == nil do
        # py create provisions a real Domain.Python subprocess (uv).
        :ok
      else
        agent_name = "py-cfg-#{System.unique_integer([:positive])}"

        assert {:ok, %{agent_uri: agent_uri}} =
                 Workspace.create_agent(
                   workspace_uri,
                   %{
                     flavor: "py",
                     name: agent_name,
                     cwd: "",
                     with_pty: false,
                     flavor_config: %{"script" => @py_script, "timeout_ms" => "10000"}
                   },
                   admin_ctx
                 )

        on_exit(fn ->
          _ = Ezagent.Domain.Python.stop(agent_uri)
          _ = Ezagent.Kind.terminate(agent_uri)
        end)

        agent_uri_str = URI.to_string(agent_uri)

        detail_state =
          IdentityData.state_for(
            %{
              component: "agent_detail",
              title: "Agent detail",
              path: "/identities/agents/#{URI.encode_www_form(agent_uri_str)}",
              entity_uri: agent_uri
            },
            %{
              workspace_uri: workspace_uri,
              caller_uri: User.admin_uri(),
              caller_caps: admin_ctx.caps
            }
          )

        config_fields = detail_state["config_fields"]

        assert is_list(config_fields),
               "config_fields must be a list for a py agent (got: #{inspect(config_fields)})"

        # py's Template config_schema declares script + timeout_ms.
        field_keys = Enum.map(config_fields, & &1["key"]) |> MapSet.new()

        assert MapSet.subset?(MapSet.new(["script", "timeout_ms"]), field_keys),
               "py agent config_fields must include script/timeout_ms; got: #{inspect(field_keys)}"
      end
    end
  end

  describe "agent detail not-wired annotations" do
    @tag :integration
    @tag :uv
    test "detail state surfaces not_wired list for missing capabilities",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      if System.find_executable("uv") == nil do
        :ok
      else
        agent_name = "notwired-#{System.unique_integer([:positive])}"

        assert {:ok, %{agent_uri: agent_uri}} =
                 Workspace.create_agent(
                   workspace_uri,
                   %{
                     flavor: "py",
                     name: agent_name,
                     cwd: "",
                     with_pty: false,
                     flavor_config: %{"script" => @py_script}
                   },
                   admin_ctx
                 )

        on_exit(fn ->
          _ = Ezagent.Domain.Python.stop(agent_uri)
          _ = Ezagent.Kind.terminate(agent_uri)
        end)

        detail_state =
          IdentityData.state_for(
            %{
              component: "agent_detail",
              title: "Agent detail",
              path: "/identities/agents/#{URI.encode_www_form(URI.to_string(agent_uri))}",
              entity_uri: agent_uri
            },
            %{
              workspace_uri: workspace_uri,
              caller_uri: User.admin_uri(),
              caller_caps: admin_ctx.caps
            }
          )

        # M1: not_wired must be present
        not_wired = detail_state["not_wired"]

        assert is_list(not_wired),
               "not_wired must be a list in agent_detail state (got: #{inspect(not_wired)})"

        # Must include the standard set of missing capabilities
        not_wired_keys = Enum.map(not_wired, & &1["key"]) |> MapSet.new()
        expected = MapSet.new(["skills", "tools", "kb", "lifecycle_detail", "settings_mgmt"])

        assert MapSet.subset?(expected, not_wired_keys),
               "not_wired must include skills/tools/kb/lifecycle_detail/settings_mgmt; got: #{inspect(not_wired_keys)}"

        # Each entry must have a reason
        for entry <- not_wired do
          assert is_binary(entry["reason"]),
                 "not_wired entry #{inspect(entry["key"])} must have a reason string"
        end
      end
    end
  end
end
