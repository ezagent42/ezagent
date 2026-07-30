defmodule Ezagent.Socialware.DefinitionTest do
  use ExUnit.Case, async: true

  alias Ezagent.Socialware.Definition

  # A real new-style ActionSet module, used as a stand-in view behavior.
  @view_mod Ezagent.ActionSet.Surface

  describe "roles field (P1 role-slot declaration)" do
    test "normalizes credential admission declarations and defaults omitted agent roles" do
      assert {:ok, definition} =
               Definition.new(%{
                 "name" => "hello",
                 "roles" => [
                   %{
                     "role_name" => "llm",
                     "fill" => "agent",
                     "recipe" => "hello.llm",
                     "flavor" => "codex",
                     "credential_admission" => "before_session_join"
                   },
                   %{
                     role_name: "helper",
                     fill: :agent,
                     recipe: "hello.helper",
                     flavor: "curl"
                   }
                 ]
               })

      assert definition.roles == [
               %{
                 role_name: "llm",
                 fill: :agent,
                 recipe: "hello.llm",
                 flavor: "codex",
                 credential_admission: :before_session_join
               },
               %{
                 role_name: "helper",
                 fill: :agent,
                 recipe: "hello.helper",
                 flavor: "curl",
                 credential_admission: :immediate
               }
             ]

      assert {:ok, round_tripped} = definition |> Definition.body() |> Definition.new()
      assert round_tripped.roles == definition.roles
    end

    test "rejects an invalid credential admission declaration" do
      assert {:error,
              {:invalid_socialware_definition_field, :credential_admission, "after_session_join"}} =
               Definition.new(%{
                 name: "hello",
                 roles: [
                   %{
                     role_name: "llm",
                     fill: :agent,
                     recipe: "hello.llm",
                     flavor: "codex",
                     credential_admission: "after_session_join"
                   }
                 ]
               })
    end

    test "accepts agent recipe slots and human slots" do
      assert {:ok, definition} =
               Definition.new(%{
                 name: "hello",
                 roles: [
                   %{role_name: "bot", fill: :agent, recipe: "hello-bot", flavor: "curl"},
                   %{role_name: "visitor", fill: :human}
                 ]
               })

      assert Map.get(definition, :roles) == [
               %{
                 role_name: "bot",
                 fill: :agent,
                 recipe: "hello-bot",
                 flavor: "curl",
                 credential_admission: :immediate
               },
               %{role_name: "visitor", fill: :human}
             ]
    end

    test "accepts string keys and normalizes fill to atoms" do
      assert {:ok, definition} =
               Definition.new(%{
                 "name" => "hello",
                 "roles" => [
                   %{
                     "role_name" => "bot",
                     "fill" => "agent",
                     "recipe" => "hello-bot",
                     "flavor" => "py"
                   },
                   %{"role_name" => "visitor", "fill" => "human"}
                 ]
               })

      assert Map.get(definition, :roles) == [
               %{
                 role_name: "bot",
                 fill: :agent,
                 recipe: "hello-bot",
                 flavor: "py",
                 credential_admission: :immediate
               },
               %{role_name: "visitor", fill: :human}
             ]
    end

    test "rejects any participant instance URI in role slots" do
      assert {:error, {:socialware_definition_declares_instance_uri, _}} =
               Definition.new(%{
                 name: "hello",
                 roles: [
                   %{
                     role_name: "bot",
                     fill: :agent,
                     recipe: "hello-bot",
                     flavor: "curl",
                     uri: "entity://acme/agent/stolen"
                   }
                 ]
               })
    end

    test "rejects participant instance URI receivers" do
      assert {:error, {:socialware_definition_declares_instance_uri, _}} =
               Definition.new(%{
                 name: "hello",
                 roles: [%{role_name: "bot", fill: :agent, recipe: "hello-bot", flavor: "curl"}],
                 routing_rules: [
                   %{
                     receivers: ["entity://acme/agent/stolen"],
                     matcher: %{"type" => "mention", "value" => "x"}
                   }
                 ]
               })
    end

    test "body/1 JSON-serializes roles and does not emit agents or members" do
      {:ok, definition} =
        Definition.new(%{
          name: "hello",
          roles: [%{role_name: "bot", fill: :agent, recipe: "hello-bot", flavor: "curl"}]
        })

      body = Definition.body(definition)

      assert body.roles == [
               %{
                 "role_name" => "bot",
                 "fill" => "agent",
                 "recipe" => "hello-bot",
                 "flavor" => "curl",
                 "credential_admission" => "immediate"
               }
             ]

      refute Map.has_key?(body, :agents)
      refute Map.has_key?(body, :members)
    end

    test "rejects retired participant declaration fields" do
      assert {:error, {:retired_socialware_definition_field, :agents}} =
               Definition.new(%{
                 name: "hello",
                 agents: [%{recipe: "hello-bot", role_name: "bot"}]
               })

      assert {:error, {:retired_socialware_definition_field, :members}} =
               Definition.new(%{
                 "name" => "hello",
                 "members" => [%{"role_name" => "bot"}]
               })
    end
  end

  describe "operates field (composition-cap declaration)" do
    test "normalizes a concrete agent-to-agent edge and round-trips it through body/1" do
      attrs = %{
        "name" => "kanban-team",
        "roles" => [
          %{
            "role_name" => "assistant",
            "fill" => "agent",
            "recipe" => "assistant",
            "flavor" => "cc",
            "operates" => [
              %{
                "role" => "board",
                "behavior" => "Ezagent.ActionSet.Sandbox",
                "action" => "read"
              }
            ]
          },
          %{"role_name" => "board", "fill" => "agent", "recipe" => "board", "flavor" => "native"}
        ]
      }

      assert {:ok, definition} = Definition.new(attrs)

      assert [assistant, _board] = definition.roles

      assert assistant.operates == [
               %{
                 role: "board",
                 behavior: Ezagent.ActionSet.Sandbox,
                 action: :read
               }
             ]

      body = Definition.body(definition)
      assert {:ok, round_tripped} = Definition.new(body)
      assert round_tripped.roles == definition.roles
    end

    test "rejects an edge whose target role is absent" do
      assert {:error, {:invalid_socialware_operates_target, "assistant", "missing"}} =
               Definition.new(%{
                 name: "missing-target",
                 roles: [
                   agent_slot("assistant",
                     operates: [operate_edge("missing")]
                   )
                 ]
               })
    end

    test "requires both source and target roles to be agent slots" do
      assert {:error, {:invalid_socialware_operates_source, "reviewer"}} =
               Definition.new(%{
                 name: "human-source",
                 roles: [
                   %{role_name: "reviewer", fill: :human, operates: [operate_edge("bot")]},
                   agent_slot("bot")
                 ]
               })

      assert {:error, {:invalid_socialware_operates_target, "bot", "reviewer"}} =
               Definition.new(%{
                 name: "human-target",
                 roles: [
                   agent_slot("bot", operates: [operate_edge("reviewer")]),
                   %{role_name: "reviewer", fill: :human}
                 ]
               })
    end

    test "rejects wildcard or undeclared actions" do
      assert {:error, {:invalid_socialware_operates_action, Ezagent.ActionSet.Sandbox, :any}} =
               Definition.new(%{
                 name: "wildcard-action",
                 roles: [
                   agent_slot("source", operates: [operate_edge("target", action: :any)]),
                   agent_slot("target")
                 ]
               })

      assert {:error, {:invalid_socialware_operates_action, Ezagent.ActionSet.Sandbox, "missing"}} =
               Definition.new(%{
                 name: "missing-action",
                 roles: [
                   agent_slot("source", operates: [operate_edge("target", action: "missing")]),
                   agent_slot("target")
                 ]
               })
    end

    test "rejects a behavior that is not a loadable ActionSet" do
      assert {:error, {:invalid_socialware_behavior, Enum}} =
               Definition.new(%{
                 name: "invalid-behavior",
                 roles: [
                   agent_slot("source", operates: [operate_edge("target", behavior: Enum)]),
                   agent_slot("target")
                 ]
               })
    end
  end

  describe "manifest metadata and uses" do
    test "accepts catalog fields and explicit plugin uses" do
      assert {:ok, %Definition{} = definition} =
               Definition.new(%{
                 name: "hello",
                 version: "1.2.3",
                 title: "Hello Socialware",
                 description: "Greets visitors",
                 uses: ["hello"],
                 visibility_policy: %{scope: :public}
               })

      assert definition.version == "1.2.3"
      assert definition.title == "Hello Socialware"
      assert definition.description == "Greets visitors"
      assert definition.uses == ["hello"]
      assert definition.visibility_policy.scope == :public

      body = Definition.body(definition)
      assert body.version == "1.2.3"
      assert body.title == "Hello Socialware"
      assert body.description == "Greets visitors"
      assert body.uses == ["hello"]
      assert body.visibility_policy["scope"] == "public"
    end

    test "defaults visibility scope to private" do
      assert {:ok, %Definition{visibility_policy: policy}} = Definition.new(%{name: "hello"})
      assert policy.scope == :private
    end
  end

  describe "views field (T2-2a, views-as-behavior)" do
    test "accepts a list of view ActionSet modules and round-trips through body/1" do
      {:ok, %Definition{views: views} = d} =
        Definition.new(%{name: "hello", views: [@view_mod]})

      assert views == [@view_mod]

      body = Definition.body(d)
      assert body.views == [Atom.to_string(@view_mod)]
      assert {:ok, %Definition{views: ^views}} = Definition.new(body)
    end

    test "views enter behaviors/1 between Session and shape" do
      {:ok, d} =
        Definition.new(%{
          name: "hello",
          views: [@view_mod],
          shape: [Ezagent.ActionSet.Session]
        })

      behaviors = Definition.behaviors(d)
      assert Ezagent.ActionSet.Session in behaviors
      assert @view_mod in behaviors
      # #189 PR-3: the SelfLicense carrier heads every set, then Session; the
      # view still precedes remaining shape/bases.
      assert hd(behaviors) == Ezagent.ActionSet.SelfLicense
      assert Enum.at(behaviors, 1) == Ezagent.ActionSet.Session
    end

    test "rejects a non-loaded / non-behavior view module" do
      assert {:error, {:invalid_socialware_behavior, _}} =
               Definition.new(%{name: "hello", views: ["Not.A.Real.Module"]})
    end

    test "defaults views to []" do
      assert {:ok, %Definition{views: []}} = Definition.new(%{name: "hello"})
    end
  end

  describe "owner_policy (P0 §7, O-1)" do
    test "T-Own-d: an owner-less body rehydrates with the :installer default" do
      assert {:ok, %Definition{owner_policy: %{type: :installer}}} =
               Definition.new(%{name: "chat"})
    end

    test "T-Own-b (derivation): :installer owner resolves to the caller" do
      caller = Ezagent.URI.user("acme", "alice")
      {:ok, definition} = Definition.new(%{name: "chat"})
      assert Definition.owner_uri(definition, caller) == caller
    end

    test "body/1 round-trips installer owner policy only" do
      {:ok, d1} = Definition.new(%{"name" => "site", "owner_policy" => %{"type" => "installer"}})

      assert d1.owner_policy == %{type: :installer}
      assert {:ok, d2} = Definition.new(Definition.body(d1))
      assert d2.owner_policy == d1.owner_policy
    end

    test "rejects :fixed owner URI declarations" do
      admin = Ezagent.Entity.User.admin_uri()

      assert {:error, {:socialware_definition_declares_owner_uri, _}} =
               Definition.new(%{name: "site", owner_policy: %{type: :fixed, uri: admin}})
    end

    test "rejects unknown or ownerless owner_policy types" do
      assert {:error, {:invalid_socialware_owner_policy, _}} =
               Definition.new(%{name: "site", owner_policy: %{type: :bogus}})

      assert {:error, {:invalid_socialware_owner_policy, _}} =
               Definition.new(%{name: "site", owner_policy: %{type: :none}})
    end
  end

  describe "T-Own-c: D-5 anon-owner invariant (§7.3)" do
    test "allows web_anon_access: true with installer-derived ownership" do
      assert {:ok, %Definition{owner_policy: %{type: :installer}}} =
               Definition.new(%{
                 name: "site",
                 visibility_policy: %{publish_policy: :auto, web_anon_access: true}
               })
    end

    test "allows web_anon_access: false with the :installer default (private def)" do
      assert {:ok, %Definition{owner_policy: %{type: :installer}}} =
               Definition.new(%{
                 name: "chat",
                 visibility_policy: %{publish_policy: :auto, web_anon_access: false}
               })
    end
  end

  describe "round-trip" do
    test "new/1 -> body/1 -> new/1 round-trips roles" do
      {:ok, d1} =
        Definition.new(%{
          name: "hello",
          roles: [
            %{role_name: "greeter", fill: :agent, recipe: "hello-greeter", flavor: "cc"}
          ]
        })

      body = Definition.body(d1)
      assert {:ok, d2} = Definition.new(body)
      assert Map.get(d2, :roles) == Map.get(d1, :roles)
    end

    test "human slot never accepts recipe, flavor, or participant URI payload" do
      assert {:ok, definition} =
               Definition.new(%{
                 name: "human-open-slot",
                 roles: [
                   %{
                     role_name: "reviewer",
                     fill: :human,
                     recipe: "ignored",
                     flavor: "cc"
                   }
                 ]
               })

      assert definition.roles == [%{role_name: "reviewer", fill: :human}]

      assert {:error, {:socialware_definition_declares_instance_uri, _}} =
               Definition.new(%{
                 name: "human-smuggles-user",
                 roles: [
                   %{
                     role_name: "reviewer",
                     fill: :human,
                     uri: "entity://system/user/alice"
                   }
                 ]
               })
    end
  end

  defp agent_slot(role_name, overrides \\ []) do
    Map.merge(
      %{role_name: role_name, fill: :agent, recipe: role_name, flavor: "native"},
      Map.new(overrides)
    )
  end

  defp operate_edge(role, overrides \\ []) do
    Map.merge(
      %{role: role, behavior: Ezagent.ActionSet.Sandbox, action: :read},
      Map.new(overrides)
    )
  end
end
