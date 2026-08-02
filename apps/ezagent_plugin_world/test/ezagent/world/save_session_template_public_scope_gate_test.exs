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

  # Actor-extraction C1: world actions re-derive the caller's caps FRESH via
  # `PresenterCaps.load/1` → `IdentityCaps.load(caller)` (no mount snapshot). Spawn
  # the caller's Identity Kind HOLDING the signed workspace caps a real logged-in
  # operator would (the spawn mints the current self-license), so the fresh load
  # returns them — mirroring production, where `current_caps` == `IdentityCaps.load`
  # at mount (live_auth.ex:234).
  defp spawn_user(uri, caps \\ []) do
    case Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: Enum.to_list(caps)}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
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

    Ezagent.Identity.Grant.grant_cap(holder, cap, {:admin, User.admin_uri()})
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
    operator_caps = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, operator).caps
    :ok = spawn_user(operator, operator_caps)
    :ok = grant_add_template(operator, workspace_uri)

    denied_app = "world165-public-#{uniq()}"

    {:noreply, denied} =
      save(workspace_uri, operator, operator_caps, "world165-tmpl-#{uniq()}", denied_app)

    assert denied.assigns.last_dispatch_status == "error:template_save_failed"

    assert denied.assigns.world_state["template_error"] =~ "public_socialware_requires_admin",
           "expected admin gate, got #{inspect(denied.assigns.world_state)}"

    # Nothing was persisted for the rejected public def.
    assert :error = DefinitionRegistry.lookup(workspace_uri, denied_app)

    # CONTROL: the authenticated canonical admin with workspace authority succeeds.
    admin = User.admin_uri()
    admin_caps = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, admin).caps
    # The canonical admin is already live; grant the durable workspace authority
    # through the dispatch path so the post-C1 fresh load returns it. This mutates
    # the SHARED admin's live Identity slice, which the Ecto sandbox does NOT roll
    # back (in-memory GenServer state) — terminate it on exit so the granted caps
    # do not leak into sibling tests that read the canonical admin.
    on_exit(fn -> Ezagent.Kind.terminate(admin) end)

    Enum.each(admin_caps, fn %Capability{} = cap ->
      :ok = Ezagent.Identity.Grant.grant_cap(admin, cap, {:admin, User.admin_uri()})
    end)

    allowed_app = "world165-public-ok-#{uniq()}"

    {:noreply, allowed} =
      save(workspace_uri, admin, admin_caps, "world165-tmpl-ok-#{uniq()}", allowed_app)

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
    caps = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, operator).caps
    :ok = spawn_user(operator, caps)
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
        caps: caps
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
            current_caps: caps,
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

    # A template saved by the workspace builder must carry its selected app's
    # role declarations into a session. This is the production path used by
    # the Sessions page; a missing declaration leaves the async installer with
    # an empty agent list and the session permanently owner-only.
    assert {:ok, session_uri, %{}} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "world-template-consumer-#{uniq()}",
               operator,
               template_name: template_name,
               workspace_uri: workspace_uri
             )

    assert [%{role_name: "front-desk", fill: :agent} | _] =
             session_uri
             |> Ezagent.Entity.Session.read_template_working_copy()
             |> Map.fetch!(:member_declarations)
  end

  test "multiple selected socialware installs save into one template manifest" do
    ws = "world-template-multi-install-#{uniq()}"
    workspace_uri = Ezagent.URI.workspace(ws)
    operator = Ezagent.URI.user(ws, "operator")
    first = "world-template-multi-a-#{uniq()}"
    second = "world-template-multi-b-#{uniq()}"
    template_name = "world-template-multi-tmpl-#{uniq()}"

    {:ok, _} = Ezagent.Workspace.create(ws, %{})
    caps = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, operator).caps
    :ok = spawn_user(operator, caps)
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

  test "a saved Hello template installs its declared role agents in the consuming session" do
    :ok = EzagentPluginHello.TestCatalog.import!()

    ws = "world-hello-template-#{uniq()}"
    workspace_uri = Ezagent.URI.workspace(ws)
    operator = Ezagent.URI.user(ws, "operator")
    template_name = "world-hello-template-#{uniq()}"

    {:ok, _} = Ezagent.Workspace.create(ws, %{})
    caps = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, operator).caps
    :ok = spawn_user(operator, caps)
    :ok = grant_add_template(operator, workspace_uri)

    {:noreply, socket} =
      save_template_params(workspace_uri, operator, caps, %{
        "name" => template_name,
        "description" => "Hello template consumed through the Sessions page",
        "installs" => [
          %{
            "ref" => "hello",
            "config" => %{
              "role_slots" => [
                %{
                  "role_name" => "llm",
                  "mode" => "fresh",
                  "flavor" => "curl",
                  "config" => %{
                    "provider" => "deepseek",
                    "api_url" => "https://api.deepseek.com/chat/completions",
                    "model" => "deepseek-v4-flash",
                    "credential_optional" => true
                  }
                }
              ]
            }
          }
        ]
      })

    assert socket.assigns.last_dispatch_status == "ok"

    # Go through the same workspace facade as the Sessions-page form. It must
    # start the post-create install Task after the owner-only session is durable.
    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    assert {:ok, %{session_uri: session_uri}} =
             Ezagent.Workspace.create_session(
               workspace_uri,
               %{short_name: "hello-consumer-#{uniq()}", template_name: template_name},
               admin_ctx
             )

    assert eventually(fn ->
             match?(
               {:ok, _front_desk_uri},
               EzagentPluginHello.Members.role_uri(session_uri, "front-desk")
             )
           end)
  end

  test "the Hello template builder defaults its LLM to a model accepted by the configured DeepSeek endpoint" do
    source =
      Path.expand("../../../assets/src/components/WorkspacePlugin.tsx", __DIR__)
      |> File.read!()

    assert source =~ "model: \"deepseek-v4-flash\""
    refute source =~ "model: \"deepseek-chat\""
  end

  test "empty socialware selection saves the same installs as the default template" do
    ws = "world-template-default-install-#{uniq()}"
    workspace_uri = Ezagent.URI.workspace(ws)
    operator = Ezagent.URI.user(ws, "operator")

    {:ok, _} = Ezagent.Workspace.create(ws, %{})
    caps = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, operator).caps
    :ok = spawn_user(operator, caps)
    :ok = grant_add_template(operator, workspace_uri)

    {:noreply, socket} =
      save_template_params(workspace_uri, operator, caps, %{
        "name" => "world-template-default-tmpl-#{uniq()}",
        "description" => "default template install"
      })

    assert socket.assigns.last_dispatch_status == "ok",
           "template save failed with #{inspect(socket.assigns.world_state)}"

    assert socket.assigns.world_state["last_socialware_refs"] == []
    assert install_refs(saved_content!(socket)) == ["chat"]
  end

  test "successful save returns from template builder to the workspaces route" do
    ws = "world-template-return-#{uniq()}"
    workspace_uri = Ezagent.URI.workspace(ws)
    operator = Ezagent.URI.user(ws, "operator")

    {:ok, _} = Ezagent.Workspace.create(ws, %{})
    caps = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, operator).caps
    :ok = spawn_user(operator, caps)
    :ok = grant_add_template(operator, workspace_uri)

    {:noreply, socket} =
      save_template_params(workspace_uri, operator, caps, %{
        "name" => "world-template-return-tmpl-#{uniq()}",
        "description" => "return to workspace detail after save"
      })

    assert socket.assigns.last_dispatch_status == "ok",
           "template save failed with #{inspect(socket.assigns.world_state)}"

    assert socket.redirected == {:live, :patch, %{kind: :push, to: "/workspaces"}}
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
