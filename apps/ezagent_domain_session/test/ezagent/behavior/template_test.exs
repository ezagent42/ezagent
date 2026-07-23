defmodule Ezagent.ActionSet.TemplateTest do
  @moduledoc """
  Phase 7 completion PR-1 (SPEC §1.0) — `Ezagent.ActionSet.Template`
  contract tests at the pure-function level.

  Dispatch-level behavior (`BehaviorRegistry` resolution, snapshot
  writes, `cap_for_action`) lives in
  `EzagentDomainInstanceMessage.Integration.BehaviorTemplateDispatchTest`.
  """

  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.Template
  alias Ezagent.Entity.{AgentTemplate, SessionTemplate}

  describe "Behavior contract surface" do
    test "actions/0 returns [:read, :write, :instantiate, :fork]" do
      # PR1 2026-05-24 (Allen): `:fork` added — generic Template-Kind concern
      # lifted out of SessionTemplate.fork/3 so AgentTemplate also gets it.
      assert Template.actions() == [:read, :write, :instantiate, :fork]
    end

    test "state_slice/0 is :template" do
      assert Template.state_slice() == :template
    end

    # Lifecycle migration (SPEC 2026-05-29 §2.3): `init_slice/1` is
    # macro-emitted, wrapping `create/1`'s persistent `%{content: ...}` in
    # the two-container `%{state:, transients:}` shape (no transients —
    # the content is fully persistent). Assert on `.state`.
    test "init_slice/1 defaults content to nil (unpopulated template Kind)" do
      # This is a pure shape test. Deliberately omit :uri so it does not
      # exercise the durable create-marker reader; marker failures correctly
      # fail closed and are covered by Lifecycle's dedicated security tests.
      assert Template.init_slice(%{}).state ==
               %{content: nil}

      assert Template.create(%{}) ==
               {:ok, %{content: nil}}
    end

    test "init_slice/1 reads args[:content]" do
      content = %{name: "x", flavor: "cc"}
      assert Template.init_slice(%{content: content}).state == %{content: content}
      assert Template.create(%{content: content}) == {:ok, %{content: content}}
    end

    test "interface/0 declares all four actions, all :call mode" do
      iface = Template.interface()
      assert Map.keys(iface) |> Enum.sort() == [:fork, :instantiate, :read, :write]
      for {_action, def} <- iface, do: assert(def.modes == [:call])
    end

    test "cap_subjects/0 includes :fork subject (PR1 — owner-grant + dispatch CapBAC)" do
      subjects = Template.cap_subjects() |> Enum.map(&elem(&1, 0))
      assert :fork in subjects
    end
  end

  describe "invoke(:read, ...)" do
    test "returns the :template slice content" do
      content = %{name: "orch", flavor: "cc"}
      slice = %{content: content}

      assert {:ok, ^slice, %{content: ^content}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Template,
                 :read,
                 slice,
                 %{},
                 %{}
               )
    end

    test "returns nil for an unpopulated slice" do
      slice = %{content: nil}

      assert {:ok, ^slice, %{content: nil}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Template,
                 :read,
                 slice,
                 %{},
                 %{}
               )
    end
  end

  describe "invoke(:write, ...) — AgentTemplate (mutable, versionless)" do
    test "plain replace into an empty slice" do
      content = %{name: "a", flavor: "cc", project_cwd: "/tmp"}
      ctx = %{kind_module: AgentTemplate}

      assert {:ok, %{content: ^content}, %{content: ^content}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Template,
                 :write,
                 %{content: nil},
                 %{content: content},
                 ctx
               )
    end

    test "overwrites an already-populated slice in place (operator edit)" do
      ctx = %{kind_module: AgentTemplate}
      old = %{name: "a", flavor: "cc", project_cwd: "/old"}
      new = %{name: "a", flavor: "cc", project_cwd: "/new"}

      assert {:ok, %{content: ^new}, %{content: ^new}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Template,
                 :write,
                 %{content: old},
                 %{content: new},
                 ctx
               )
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
        orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
        default_workspace_uri: Ezagent.URI.new!("workspace://team-alpha")
      }
    end

    defp st_uri(content) do
      hash = SessionTemplate.compute_version_hash(content)
      SessionTemplate.build_uri("code-review", hash, workspace: "team-alpha")
    end

    test "first write into an empty slice succeeds when URI hash matches content" do
      content = st_content()
      ctx = %{kind_module: SessionTemplate, self_uri: st_uri(content)}

      assert {:ok, %{content: ^content}, %{content: ^content}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Template,
                 :write,
                 %{content: nil},
                 %{content: content},
                 ctx
               )
    end

    test "a hash-mismatched write → {:error, :hash_mismatch}" do
      content = st_content()
      # URI built from DIFFERENT content → its @<hash> won't match.
      wrong_uri = st_uri(%{content | description: "different team"})
      ctx = %{kind_module: SessionTemplate, self_uri: wrong_uri}

      assert {:error, :hash_mismatch} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Template,
                 :write,
                 %{content: nil},
                 %{content: content},
                 ctx
               )
    end

    test "a second DIVERGENT write to a populated slice → {:error, :immutable_version}" do
      content = st_content()

      # Slice already populated with `content`; a divergent write of
      # different content (whose hash happens to match its OWN uri, but
      # the slice is already non-empty) must be rejected.
      divergent = %{content | description: "tampered"}
      divergent_ctx = %{kind_module: SessionTemplate, self_uri: st_uri(divergent)}

      assert {:error, :immutable_version} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Template,
                 :write,
                 %{content: content},
                 %{content: divergent},
                 divergent_ctx
               )
    end

    test "an idempotent retry (identical content) to a populated slice no-ops as success" do
      content = st_content()
      ctx = %{kind_module: SessionTemplate, self_uri: st_uri(content)}

      assert {:ok, %{content: ^content}, %{content: ^content}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Template,
                 :write,
                 %{content: content},
                 %{content: content},
                 ctx
               )
    end
  end

  describe "invoke(:instantiate, ...) — SessionTemplate" do
    test "returns {:error, :use_generator} — SessionTemplate instantiation IS the Generator" do
      ctx = %{
        kind_module: SessionTemplate,
        self_uri: URI.new!("template://team-alpha/session/x@h")
      }

      slice = %{content: %{name: "x"}}

      assert {:error, :use_generator} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Template,
                 :instantiate,
                 slice,
                 %{},
                 ctx
               )
    end
  end

  describe "invoke(:instantiate, ...) — AgentTemplate" do
    test "returns {:error, :template_not_populated} for an empty slice" do
      ctx = %{kind_module: AgentTemplate, self_uri: URI.new!("template://team-alpha/agent/x")}

      assert {:error, :template_not_populated} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Template,
                 :instantiate,
                 %{content: nil},
                 %{},
                 ctx
               )
    end
  end

  # codex HIGH-1 — `template.instantiate` is CapBAC-checked against the
  # AgentTemplate's OWN URI, so only that workspace is authorized. An
  # explicit `args.workspace_uri` must NOT be trusted as the spawn
  # destination: a caller authorized for workspace A must not be able
  # to spawn + bind a worker into workspace B by passing
  # `workspace_uri: workspace://B`.
  describe "invoke(:instantiate, ...) — AgentTemplate workspace-escape (codex HIGH-1)" do
    # An AgentTemplate URI in `default`; the slice carries a flavor so
    # the only thing standing between the call and a spawn is the
    # cross-workspace guard.
    defp agent_template_content do
      %{name: "cc-orch", flavor: "cc", project_cwd: "/tmp/proj"}
    end

    test "a workspace_uri arg pointing at ANOTHER workspace → {:error, :cross_workspace_denied}" do
      # AgentTemplate cap-checked for workspace `alpha`; caller tries
      # to escape into `team-bravo` via the workspace_uri arg.
      self_uri = URI.new!("template://alpha/agent/cc-orch")
      ctx = %{kind_module: AgentTemplate, self_uri: self_uri}
      slice = %{content: agent_template_content()}

      assert {:error, :cross_workspace_denied} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Template,
                 :instantiate,
                 slice,
                 %{instance_name: "demo", workspace_uri: URI.new!("workspace://team-bravo")},
                 ctx
               )

      # The reject happens BEFORE any spawn — `resolve_instance_uri`
      # short-circuits the `with` chain so `spawn_from_template_content`
      # is never reached and NO worker is spawned/bound in `team-bravo`.
      # (Proven structurally: the guard is the first step of the chain;
      #  an integration spawn-count assertion lives in PR-4/PR-5.)
    end

    test "a workspace_uri arg pointing at a per-tenant URI in another workspace is also denied" do
      # The guard normalizes through `workspace_of/1`, so passing an
      # entity:// URI carrying `team-bravo` is rejected just the same
      # when the self_uri is in `alpha`.
      self_uri = URI.new!("template://alpha/agent/cc-orch")
      ctx = %{kind_module: AgentTemplate, self_uri: self_uri}
      slice = %{content: agent_template_content()}

      assert {:error, :cross_workspace_denied} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Template,
                 :instantiate,
                 slice,
                 %{
                   instance_name: "demo",
                   workspace_uri: URI.new!("entity://team-bravo/agent/cc_other")
                 },
                 ctx
               )
    end

    test "a workspace_uri arg MATCHING the AgentTemplate's own workspace is allowed" do
      # Same workspace — the guard passes. The instance URI is built in
      # the cap-checked workspace; the spawn helper would then run (it
      # crashes here only because no real registry/flavor is wired in a
      # pure unit test — the point is the guard did NOT reject).
      self_uri = URI.new!("template://team-alpha/agent/cc-orch")
      ctx = %{kind_module: AgentTemplate, self_uri: self_uri}
      slice = %{content: agent_template_content()}

      result =
        EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
          Ezagent.ActionSet.Template,
          :instantiate,
          slice,
          %{instance_name: "demo", workspace_uri: URI.new!("workspace://team-alpha")},
          ctx
        )

      refute match?({:error, :cross_workspace_denied}, result),
             "a workspace_uri matching the AgentTemplate's own workspace must NOT be rejected"
    end

    test "no workspace_uri arg → destination derived from the AgentTemplate URI, not rejected" do
      self_uri = URI.new!("template://team-alpha/agent/cc-orch")
      ctx = %{kind_module: AgentTemplate, self_uri: self_uri}
      slice = %{content: agent_template_content()}

      result =
        EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
          Ezagent.ActionSet.Template,
          :instantiate,
          slice,
          %{instance_name: "demo"},
          ctx
        )

      refute match?({:error, :cross_workspace_denied}, result),
             "the happy path (no workspace_uri arg) must derive the workspace " <>
               "from the cap-checked AgentTemplate URI and proceed"
    end
  end
end
