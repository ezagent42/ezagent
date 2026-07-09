defmodule Ezagent.World.SaveSessionTemplatePublicScopeGateTest do
  # SECURITY (#165) — the world operator template form must NOT let a non-admin
  # workspace operator publish a `visibility_policy.scope: :public` socialware
  # Definition into the cross-tenant installable catalog. The sub-bug was that
  # `save_session_template/2` never read `socket.assigns.current_caps`, so the
  # domain public-scope admin gate saw no caps. This proves the fixed action:
  # threads the operator's real caps, and the domain gate denies a non-admin
  # public publish (surfacing `public_socialware_requires_admin` WITHOUT persisting
  # the socialware def) while an admin publish succeeds.
  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.{Definition, DefinitionRegistry}
  alias Ezagent.TemplateTags
  alias Ezagent.World.WorkspacePluginActions

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_world)
    :ok = DefinitionRegistry.seed_builtin_definitions()
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp spawn_user(uri) do
    case Ezagent.Kind.spawn(User, %{uri: uri}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp grant_add_template(holder, workspace_uri) do
    cap =
      Capability.cap(
        :workspace,
        Ezagent.ActionSet.Workspace,
        :add_template,
        workspace_uri,
        workspace_uri
      )

    Ezagent.Identity.Grant.grant_cap(holder, cap, {:genesis, User.admin_uri()})
  end

  defp public_socialware_form(name) do
    %{
      "name" => name,
      "bases" => ["Ezagent.ActionSet.Session", "Ezagent.ActionSet.Publisher.SessionImpl"],
      "shape" => ["Ezagent.ActionSet.Turn", "Ezagent.ActionSet.Surface"],
      "roles" => [
        %{"role_name" => "bot", "fill" => "agent", "recipe" => "x", "flavor" => "native"}
      ],
      "routing_rules" => [
        %{
          "matcher" => %{"type" => "always"},
          "receivers" => ["bot"],
          "rule_set" => "default",
          "position" => 0,
          "prompt_template_ref" => "answer"
        }
      ],
      "prompt_templates" => %{"answer" => "Answer."},
      "legends" => %{
        "support" => %{"member_set" => ["bot"], "bound_rule_set" => "default", "fold" => false}
      },
      "adapters" => [%{"adapter_id" => "web_feed", "role" => "customer", "config" => %{}}],
      # The headline: scope PUBLIC → cross-tenant catalog → admin required.
      "visibility_policy" => %{
        "scope" => "public",
        "publish_policy" => "auto",
        "web_anon_access" => true
      }
    }
  end

  defp save(workspace_uri, caller, caps, template_name, socialware_name) do
    save_template_params(workspace_uri, caller, caps, %{
      "name" => template_name,
      "description" => "gate #{template_name}",
      "socialware" => public_socialware_form(socialware_name)
    })
  end

  defp save_template_params(workspace_uri, caller, caps, params) do
    WorkspacePluginActions.save_session_template(
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          current_entity_uri: caller,
          current_workspace_uri: workspace_uri,
          current_caps: caps,
          world_state: %{}
        }
      },
      params
    )
  end

  defp write_selectable_definition(workspace_uri, caller, caps, name, role_name) do
    {:ok, definition} =
      Definition.new(%{
        name: name,
        title: "Install app #{name}",
        bases: [Ezagent.ActionSet.Session],
        roles: [
          %{
            role_name: role_name,
            fill: :agent,
            recipe: "hello.front-desk",
            flavor: "hello"
          }
        ],
        visibility_policy: %{publish_policy: :auto, web_anon_access: true}
      })

    DefinitionRegistry.write_definition(definition,
      workspace_uri: workspace_uri,
      caller_workspace_uri: workspace_uri,
      actor_uri: caller,
      caps: caps
    )
  end

  defp saved_content!(socket) do
    {:ok, template_uri} = Ezagent.URI.parse(socket.assigns.world_state["last_template_uri"])
    {:ok, content} = Ezagent.Entity.Session.read_template_content(template_uri)
    content
  end

  defp install_refs(content) do
    content
    |> Map.get(:installs, Map.get(content, "installs", []))
    |> Enum.map(&install_ref/1)
  end

  defp install_ref(ref) when is_binary(ref), do: ref
  defp install_ref(%{"ref" => ref}), do: ref
  defp install_ref(%{ref: ref}), do: ref

  test "non-admin operator CANNOT publish a public socialware app; admin CAN" do
    ws = "world165-#{uniq()}"
    workspace_uri = Ezagent.URI.workspace(ws)
    operator = Ezagent.URI.user(ws, "operator")

    {:ok, _} = Ezagent.Workspace.create(ws, %{})
    :ok = spawn_user(operator)
    :ok = grant_add_template(operator, workspace_uri)

    operator_caps =
      MapSet.new([
        Capability.cap(
          :workspace,
          Ezagent.ActionSet.Workspace,
          :add_template,
          workspace_uri,
          workspace_uri
        )
      ])

    denied_app = "world165-public-#{uniq()}"

    {:noreply, denied} =
      save(workspace_uri, operator, operator_caps, "world165-tmpl-#{uniq()}", denied_app)

    assert denied.assigns.last_dispatch_status == "error:template_save_failed"

    assert denied.assigns.world_state["template_error"] =~ "public_socialware_requires_admin",
           "expected admin gate, got #{inspect(denied.assigns.world_state)}"

    # Nothing was persisted for the rejected public def.
    assert :error = DefinitionRegistry.lookup(workspace_uri, denied_app)

    # CONTROL: the SAME operator with admin authority in current_caps succeeds.
    admin_caps = MapSet.new([Capability.admin_genesis_cap()])
    allowed_app = "world165-public-ok-#{uniq()}"

    {:noreply, allowed} =
      save(workspace_uri, operator, admin_caps, "world165-tmpl-ok-#{uniq()}", allowed_app)

    assert allowed.assigns.last_dispatch_status == "ok",
           "admin publish failed with #{inspect(allowed.assigns.world_state)}"

    assert {:ok, _def, _obj} = DefinitionRegistry.lookup(workspace_uri, allowed_app)
  end

  test "selected socialware install saves into the template manifest and publishes current tag" do
    ws = "world-template-install-#{uniq()}"
    workspace_uri = Ezagent.URI.workspace(ws)
    operator = Ezagent.URI.user(ws, "operator")
    socialware_name = "world-template-install-app-#{uniq()}"
    template_name = "world-template-install-tmpl-#{uniq()}"

    {:ok, _} = Ezagent.Workspace.create(ws, %{})
    :ok = spawn_user(operator)
    :ok = grant_add_template(operator, workspace_uri)

    {:ok, definition} =
      Definition.new(%{
        name: socialware_name,
        title: "Install app",
        bases: [Ezagent.ActionSet.Session],
        roles: [
          %{
            role_name: "front-desk",
            fill: :agent,
            recipe: "hello.front-desk",
            flavor: "hello"
          }
        ],
        visibility_policy: %{publish_policy: :auto, web_anon_access: true}
      })

    {:ok, _object} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: workspace_uri,
        caller_workspace_uri: workspace_uri,
        actor_uri: operator,
        caps: MapSet.new([Capability.admin_genesis_cap()])
      )

    role_slots = [
      %{"role_name" => "front-desk", "mode" => "fresh", "flavor" => "hello"}
    ]

    {:noreply, socket} =
      WorkspacePluginActions.save_session_template(
        %Phoenix.LiveView.Socket{
          assigns: %{
            __changed__: %{},
            current_entity_uri: operator,
            current_workspace_uri: workspace_uri,
            current_caps: MapSet.new([Capability.admin_genesis_cap()]),
            world_state: %{}
          }
        },
        %{
          "name" => template_name,
          "description" => "template install",
          "installs" => [
            %{"ref" => socialware_name, "config" => %{"role_slots" => role_slots}}
          ]
        }
      )

    assert socket.assigns.last_dispatch_status == "ok",
           "template save failed with #{inspect(socket.assigns.world_state)}"

    assert socket.assigns.world_state["last_socialware_ref"] == socialware_name
    assert socket.assigns.world_state["last_socialware_refs"] == [socialware_name]
    assert {:ok, hash} = TemplateTags.resolve(workspace_uri, template_name, "current")
    assert is_binary(hash) and hash != ""
  end

  test "multiple selected socialware installs save into one template manifest" do
    ws = "world-template-multi-install-#{uniq()}"
    workspace_uri = Ezagent.URI.workspace(ws)
    operator = Ezagent.URI.user(ws, "operator")
    caps = MapSet.new([Capability.admin_genesis_cap()])
    first = "world-template-multi-a-#{uniq()}"
    second = "world-template-multi-b-#{uniq()}"
    template_name = "world-template-multi-tmpl-#{uniq()}"

    {:ok, _} = Ezagent.Workspace.create(ws, %{})
    :ok = spawn_user(operator)
    :ok = grant_add_template(operator, workspace_uri)
    {:ok, _} = write_selectable_definition(workspace_uri, operator, caps, first, "front-desk")
    {:ok, _} = write_selectable_definition(workspace_uri, operator, caps, second, "builder")

    {:noreply, socket} =
      save_template_params(workspace_uri, operator, caps, %{
        "name" => template_name,
        "description" => "multi template install",
        "installs" => [
          %{
            "ref" => first,
            "config" => %{
              "role_slots" => [
                %{"role_name" => "front-desk", "mode" => "fresh", "flavor" => "hello"}
              ]
            }
          },
          %{
            "ref" => second,
            "config" => %{
              "role_slots" => [
                %{"role_name" => "builder", "mode" => "fresh", "flavor" => "hello"}
              ]
            }
          }
        ]
      })

    assert socket.assigns.last_dispatch_status == "ok",
           "template save failed with #{inspect(socket.assigns.world_state)}"

    assert socket.assigns.world_state["last_socialware_refs"] == [first, second]
    assert install_refs(saved_content!(socket)) == [first, second]
    assert {:ok, hash} = TemplateTags.resolve(workspace_uri, template_name, "current")
    assert is_binary(hash) and hash != ""
  end

  test "empty socialware selection saves the same installs as the default template" do
    ws = "world-template-default-install-#{uniq()}"
    workspace_uri = Ezagent.URI.workspace(ws)
    operator = Ezagent.URI.user(ws, "operator")
    caps = MapSet.new([Capability.admin_genesis_cap()])

    {:ok, _} = Ezagent.Workspace.create(ws, %{})
    :ok = spawn_user(operator)
    :ok = grant_add_template(operator, workspace_uri)

    {:noreply, socket} =
      save_template_params(workspace_uri, operator, caps, %{
        "name" => "world-template-default-tmpl-#{uniq()}",
        "description" => "default template install"
      })

    assert socket.assigns.last_dispatch_status == "ok",
           "template save failed with #{inspect(socket.assigns.world_state)}"

    assert socket.assigns.world_state["last_socialware_refs"] == []
    assert install_refs(saved_content!(socket)) == ["chat", "orchestrator"]
  end

  test "successful save returns from template builder to the workspace detail route" do
    ws = "world-template-return-#{uniq()}"
    workspace_uri = Ezagent.URI.workspace(ws)
    operator = Ezagent.URI.user(ws, "operator")
    caps = MapSet.new([Capability.admin_genesis_cap()])

    {:ok, _} = Ezagent.Workspace.create(ws, %{})
    :ok = spawn_user(operator)
    :ok = grant_add_template(operator, workspace_uri)

    {:noreply, socket} =
      save_template_params(workspace_uri, operator, caps, %{
        "name" => "world-template-return-tmpl-#{uniq()}",
        "description" => "return to workspace detail after save"
      })

    assert socket.assigns.last_dispatch_status == "ok",
           "template save failed with #{inspect(socket.assigns.world_state)}"

    assert socket.redirected ==
             {:live, :patch, %{kind: :push, to: "/workspaces/#{URI.encode_www_form(ws)}"}}
  end
end
