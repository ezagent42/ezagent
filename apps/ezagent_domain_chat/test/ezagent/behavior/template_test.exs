defmodule Ezagent.Behavior.TemplateTest do
  @moduledoc """
  Phase 7 completion PR-1 (SPEC §1.0) — `Ezagent.Behavior.Template`
  contract tests at the pure-function level.

  Dispatch-level behavior (`BehaviorRegistry` resolution, snapshot
  writes, `cap_for_action`) lives in
  `EzagentDomainChat.Integration.BehaviorTemplateDispatchTest`.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Template
  alias Ezagent.Entity.{AgentTemplate, SessionTemplate}

  describe "Behavior contract surface" do
    test "actions/0 returns [:read, :write, :instantiate]" do
      assert Template.actions() == [:read, :write, :instantiate]
    end

    test "state_slice/0 is :template" do
      assert Template.state_slice() == :template
    end

    test "init_slice/1 defaults content to nil (unpopulated template Kind)" do
      assert Template.init_slice(%{uri: URI.new!("template://agent/default/x")}) ==
               %{content: nil}
    end

    test "init_slice/1 reads args[:content]" do
      content = %{name: "x", flavor: "cc"}
      assert Template.init_slice(%{content: content}) == %{content: content}
    end

    test "interface/0 declares all three actions, all :call mode" do
      iface = Template.interface()
      assert Map.keys(iface) |> Enum.sort() == [:instantiate, :read, :write]
      for {_action, def} <- iface, do: assert(def.modes == [:call])
    end
  end

  describe "invoke(:read, ...)" do
    test "returns the :template slice content" do
      content = %{name: "orch", flavor: "cc"}
      slice = %{content: content}

      assert {:ok, ^slice, %{content: ^content}} = Template.invoke(:read, slice, %{}, %{})
    end

    test "returns nil for an unpopulated slice" do
      slice = %{content: nil}
      assert {:ok, ^slice, %{content: nil}} = Template.invoke(:read, slice, %{}, %{})
    end
  end

  describe "invoke(:write, ...) — AgentTemplate (mutable, versionless)" do
    test "plain replace into an empty slice" do
      content = %{name: "a", flavor: "cc", working_directory: "/tmp"}
      ctx = %{kind_module: AgentTemplate}

      assert {:ok, %{content: ^content}, %{content: ^content}} =
               Template.invoke(:write, %{content: nil}, %{content: content}, ctx)
    end

    test "overwrites an already-populated slice in place (operator edit)" do
      ctx = %{kind_module: AgentTemplate}
      old = %{name: "a", flavor: "cc", working_directory: "/old"}
      new = %{name: "a", flavor: "cc", working_directory: "/new"}

      assert {:ok, %{content: ^new}, %{content: ^new}} =
               Template.invoke(:write, %{content: old}, %{content: new}, ctx)
    end
  end

  describe "invoke(:write, ...) — SessionTemplate (write-once + hash-checked)" do
    # Build content + the matching content-addressed URI.
    defp st_content do
      %{
        name: "code-review",
        description: "team",
        agent_slots: [],
        routing_rules: [],
        orchestrator_template_uri: URI.parse("template://agent/default/cc-orchestrator"),
        default_workspace_uri: URI.parse("workspace://default")
      }
    end

    defp st_uri(content) do
      hash = SessionTemplate.compute_version_hash(content)
      SessionTemplate.build_uri("code-review", hash)
    end

    test "first write into an empty slice succeeds when URI hash matches content" do
      content = st_content()
      ctx = %{kind_module: SessionTemplate, self_uri: st_uri(content)}

      assert {:ok, %{content: ^content}, %{content: ^content}} =
               Template.invoke(:write, %{content: nil}, %{content: content}, ctx)
    end

    test "a hash-mismatched write → {:error, :hash_mismatch}" do
      content = st_content()
      # URI built from DIFFERENT content → its @<hash> won't match.
      wrong_uri = st_uri(%{content | description: "different team"})
      ctx = %{kind_module: SessionTemplate, self_uri: wrong_uri}

      assert {:error, :hash_mismatch} =
               Template.invoke(:write, %{content: nil}, %{content: content}, ctx)
    end

    test "a second DIVERGENT write to a populated slice → {:error, :immutable_version}" do
      content = st_content()

      # Slice already populated with `content`; a divergent write of
      # different content (whose hash happens to match its OWN uri, but
      # the slice is already non-empty) must be rejected.
      divergent = %{content | description: "tampered"}
      divergent_ctx = %{kind_module: SessionTemplate, self_uri: st_uri(divergent)}

      assert {:error, :immutable_version} =
               Template.invoke(:write, %{content: content}, %{content: divergent}, divergent_ctx)
    end

    test "an idempotent retry (identical content) to a populated slice no-ops as success" do
      content = st_content()
      ctx = %{kind_module: SessionTemplate, self_uri: st_uri(content)}

      assert {:ok, %{content: ^content}, %{content: ^content}} =
               Template.invoke(:write, %{content: content}, %{content: content}, ctx)
    end
  end

  describe "invoke(:instantiate, ...) — SessionTemplate" do
    test "returns {:error, :use_generator} — SessionTemplate instantiation IS the Generator" do
      ctx = %{kind_module: SessionTemplate, self_uri: URI.new!("template://session/default/x@h")}
      slice = %{content: %{name: "x"}}

      assert {:error, :use_generator} = Template.invoke(:instantiate, slice, %{}, ctx)
    end
  end

  describe "invoke(:instantiate, ...) — AgentTemplate" do
    test "returns {:error, :template_not_populated} for an empty slice" do
      ctx = %{kind_module: AgentTemplate, self_uri: URI.new!("template://agent/default/x")}

      assert {:error, :template_not_populated} =
               Template.invoke(:instantiate, %{content: nil}, %{}, ctx)
    end
  end
end
