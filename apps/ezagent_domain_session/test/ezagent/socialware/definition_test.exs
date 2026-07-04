defmodule Ezagent.Socialware.DefinitionTest do
  use ExUnit.Case, async: true

  alias Ezagent.Socialware.Definition

  # A real new-style ActionSet module, used as a stand-in view behavior.
  @view_mod Ezagent.ActionSet.Surface

  describe "agents field (T2-1, shape-only validation)" do
    test "accepts a list of %{recipe, role_name} with atom keys" do
      assert {:ok, %Definition{agents: agents}} =
               Definition.new(%{
                 name: "hello",
                 agents: [%{recipe: "hello-greeter", role_name: "greeter"}]
               })

      assert agents == [%{recipe: "hello-greeter", role_name: "greeter", flavor: "cc"}]
    end

    test "accepts string keys (persisted JSON round-trip) and normalizes to atom keys" do
      assert {:ok, %Definition{agents: agents}} =
               Definition.new(%{
                 "name" => "hello",
                 "agents" => [%{"recipe" => "hello-greeter", "role_name" => "greeter"}]
               })

      assert agents == [%{recipe: "hello-greeter", role_name: "greeter", flavor: "cc"}]
    end

    test "defaults to [] when absent" do
      assert {:ok, %Definition{agents: []}} = Definition.new(%{name: "hello"})
    end

    test "rejects a non-list agents value" do
      assert {:error, {:invalid_socialware_definition_field, :agents, _}} =
               Definition.new(%{name: "hello", agents: %{recipe: "x", role_name: "y"}})
    end

    test "rejects an agent with a blank recipe" do
      assert {:error, {:invalid_socialware_agent, _}} =
               Definition.new(%{name: "hello", agents: [%{recipe: "", role_name: "greeter"}]})
    end

    test "rejects an agent with a missing role_name" do
      assert {:error, {:invalid_socialware_agent, _}} =
               Definition.new(%{name: "hello", agents: [%{recipe: "hello-greeter"}]})
    end

    test "does NOT resolve recipe existence in new/1 (shape only)" do
      # a wholly nonexistent recipe name is still accepted at the shape boundary
      assert {:ok, %Definition{}} =
               Definition.new(%{
                 name: "hello",
                 agents: [%{recipe: "no-such-recipe-anywhere", role_name: "ghost"}]
               })
    end

    test "body/1 JSON-serializes agents as string-keyed maps" do
      {:ok, definition} =
        Definition.new(%{
          name: "hello",
          agents: [%{recipe: "hello-greeter", role_name: "greeter"}]
        })

      body = Definition.body(definition)

      assert body.agents == [
               %{"recipe" => "hello-greeter", "role_name" => "greeter", "flavor" => "cc"}
             ]
    end

    test "accepts optional flavor and defaults it to cc" do
      assert {:ok, %Definition{agents: agents}} =
               Definition.new(%{
                 name: "hello",
                 agents: [
                   %{recipe: "hello-greeter", role_name: "greeter"},
                   %{recipe: "hello-worker", role_name: "worker", flavor: "py"}
                 ]
               })

      assert agents == [
               %{recipe: "hello-greeter", role_name: "greeter", flavor: "cc"},
               %{recipe: "hello-worker", role_name: "worker", flavor: "py"}
             ]
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
      # Session is first; the view precedes remaining shape/bases.
      assert hd(behaviors) == Ezagent.ActionSet.Session
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
    @admin Ezagent.Entity.User.admin_uri()

    test "T-Own-d: an owner-less body rehydrates with the :installer default" do
      assert {:ok, %Definition{owner_policy: %{type: :installer}}} =
               Definition.new(%{name: "chat"})
    end

    test "T-Own-b (derivation): :installer owner resolves to the caller" do
      caller = Ezagent.URI.user("acme", "alice")
      {:ok, definition} = Definition.new(%{name: "chat"})
      assert Definition.owner_uri(definition, caller) == caller
    end

    test "T-Own-a (derivation): :fixed owner resolves to the declared uri" do
      {:ok, definition} =
        Definition.new(%{name: "site", owner_policy: %{type: :fixed, uri: @admin}})

      caller = Ezagent.URI.user("acme", "alice")
      assert Definition.owner_uri(definition, caller) == @admin
    end

    test ":none owner resolves to nil (ownerless)" do
      {:ok, definition} = Definition.new(%{name: "chat", owner_policy: %{type: :none}})
      assert Definition.owner_uri(definition, Ezagent.URI.user("acme", "alice")) == nil
    end

    test ":fixed accepts a string uri and round-trips through body/1" do
      {:ok, d1} =
        Definition.new(%{
          "name" => "site",
          "owner_policy" => %{"type" => "fixed", "uri" => URI.to_string(@admin)}
        })

      assert d1.owner_policy == %{type: :fixed, uri: @admin}
      assert {:ok, d2} = Definition.new(Definition.body(d1))
      assert d2.owner_policy == d1.owner_policy
    end

    test "rejects :fixed with no/invalid uri (fail loud, no default-swallow)" do
      assert {:error, {:invalid_socialware_owner_policy, _}} =
               Definition.new(%{name: "site", owner_policy: %{type: :fixed}})
    end

    test "rejects an unknown owner_policy type" do
      assert {:error, {:invalid_socialware_owner_policy, _}} =
               Definition.new(%{name: "site", owner_policy: %{type: :bogus}})
    end
  end

  describe "T-Own-c: D-5 anon-owner invariant (§7.3)" do
    @admin Ezagent.Entity.User.admin_uri()

    test "REJECTS web_anon_access: true with owner_policy :installer" do
      assert {:error, {:anon_definition_requires_fixed_owner, :installer}} =
               Definition.new(%{
                 name: "site",
                 visibility_policy: %{publish_policy: :auto, web_anon_access: true}
               })
    end

    test "REJECTS web_anon_access: true with owner_policy :none" do
      assert {:error, {:anon_definition_requires_fixed_owner, :none}} =
               Definition.new(%{
                 name: "site",
                 owner_policy: %{type: :none},
                 visibility_policy: %{publish_policy: :auto, web_anon_access: true}
               })
    end

    test "ACCEPTS web_anon_access: true with owner_policy :fixed" do
      assert {:ok, %Definition{owner_policy: %{type: :fixed, uri: @admin}}} =
               Definition.new(%{
                 name: "site",
                 owner_policy: %{type: :fixed, uri: @admin},
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
    test "new/1 -> body/1 -> new/1 round-trips agents" do
      {:ok, d1} =
        Definition.new(%{
          name: "hello",
          agents: [%{recipe: "hello-greeter", role_name: "greeter"}]
        })

      body = Definition.body(d1)
      assert {:ok, d2} = Definition.new(body)
      assert d2.agents == d1.agents
    end
  end
end
