defmodule Ezagent.ActionSet.TemplateMigrationParityTest do
  @moduledoc """
  Phase 2-a r3 (2026-05-28) — migration parity tests for
  `Ezagent.ActionSet.Template` after the SPEC 2026-05-28
  new-action-grammar migration.

  Covers the four actions (:read / :write / :instantiate / :fork)
  via their `handle_<action>/2` shape, asserting:
  - Same arguments produce the same final slice state
  - Effects produced match the expected effect list shape
  - Error paths return the expected typed errors
  """

  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.Template
  alias Ezagent.Entity.{AgentTemplate, SessionTemplate}

  defp ctx_with_slice(content, extras \\ %{}) do
    Map.merge(
      %{
        read: fn key, default ->
          case key do
            :content -> content
            _ -> default
          end
        end,
        kind_module: AgentTemplate,
        self_uri: nil,
        caller: nil,
        authenticated_principal: nil,
        caps: MapSet.new()
      },
      extras
    )
  end

  describe "new-contract surface" do
    test "is a new-style Behavior" do
      assert Template.__behavior__?() == true
    end

    test "declares the four actions in canonical order" do
      assert Enum.sort(Template.__action_names__()) ==
               [:fork, :instantiate, :read, :write]
    end

    test "state_slice/0 is :template" do
      assert Template.state_slice() == :template
    end

    # Lifecycle migration (SPEC 2026-05-29 §2.3): `init_slice/1` wraps
    # `create/1`'s persistent `%{content: ...}` in the two-container
    # shape (no transients). Assert on `.state`.
    test "init_slice/1 reads :content key (default nil)" do
      assert Template.init_slice(%{}).state == %{content: nil}
      assert Template.init_slice(%{content: %{x: 1}}).state == %{content: %{x: 1}}
    end

    test "workspace_scoped? is false (cross-cutting template:// URIs)" do
      # Per-action override via the macro is read at runtime.
      assert Template.__action_spec__(:read).workspace_scoped? == false
      assert Template.__action_spec__(:write).workspace_scoped? == false
      assert Template.__action_spec__(:instantiate).workspace_scoped? == false
      assert Template.__action_spec__(:fork).workspace_scoped? == false
    end
  end

  describe "handle_read/2 — pure pass-through of slice content" do
    test "with content populated returns {:ok, %{content: c}, []}" do
      content = %{name: "demo", flavor: "cc"}
      ctx = ctx_with_slice(content)

      assert {:ok, %{content: ^content}, []} = Template.handle_read(%{}, ctx)
    end

    test "with nil content returns {:ok, %{content: nil}, []}" do
      ctx = ctx_with_slice(nil)

      assert {:ok, %{content: nil}, []} = Template.handle_read(%{}, ctx)
    end

    test "produces NO :set effect (read is non-mutating)" do
      ctx = ctx_with_slice(%{x: 1})
      assert {:ok, _result, []} = Template.handle_read(%{}, ctx)
    end
  end

  describe "handle_write/2 — AgentTemplate (mutable replace)" do
    test "writes content as :set effect on AgentTemplate" do
      content = %{name: "demo", flavor: "cc"}
      ctx = ctx_with_slice(nil, %{kind_module: AgentTemplate})

      assert {:ok, %{content: ^content}, effects} =
               Template.handle_write(%{content: content}, ctx)

      assert Enum.any?(effects, fn
               {:set, :content, c} -> c == content
               _ -> false
             end)
    end

    test "AgentTemplate write overwrites prior content (versionless = mutable)" do
      old = %{name: "demo", flavor: "cc", version: 1}
      new = %{name: "demo", flavor: "cc", version: 2}
      ctx = ctx_with_slice(old, %{kind_module: AgentTemplate})

      assert {:ok, %{content: ^new}, [{:set, :content, ^new}]} =
               Template.handle_write(%{content: new}, ctx)
    end
  end

  describe "handle_write/2 — SessionTemplate (immutable + hash-checked)" do
    test "without a self_uri carrying a @<hash> segment → :missing_version_hash_in_uri" do
      ctx = ctx_with_slice(nil, %{kind_module: SessionTemplate, self_uri: nil})

      assert {:error, :missing_version_hash_in_uri} =
               Template.handle_write(%{content: %{name: "x"}}, ctx)
    end

    test "with self_uri but wrong content hash → :hash_mismatch" do
      uri = Ezagent.URI.new!("template://team-alpha/session/demo@wronghash123")
      ctx = ctx_with_slice(nil, %{kind_module: SessionTemplate, self_uri: uri})

      content = %{name: "demo", agent_slots: [], routing_rules: []}
      assert {:error, :hash_mismatch} = Template.handle_write(%{content: content}, ctx)
    end
  end

  describe "handle_write/2 — unsupported kind" do
    test "non-Agent/SessionTemplate Kind → typed error" do
      ctx = ctx_with_slice(nil, %{kind_module: SomeOtherKind})

      assert {:error, {:template_write_unsupported_for_kind, SomeOtherKind}} =
               Template.handle_write(%{content: %{}}, ctx)
    end
  end

  describe "handle_instantiate/2 — SessionTemplate redirects to Generator" do
    test "returns {:error, :use_generator} on SessionTemplate Kind" do
      ctx = ctx_with_slice(%{name: "x"}, %{kind_module: SessionTemplate})

      assert {:error, :use_generator} = Template.handle_instantiate(%{}, ctx)
    end
  end

  describe "handle_instantiate/2 — AgentTemplate without populated content" do
    test "returns :template_not_populated when slice content is nil" do
      ctx =
        ctx_with_slice(nil, %{
          kind_module: AgentTemplate,
          self_uri: Ezagent.URI.new!("template://team-alpha/agent/demo")
        })

      assert {:error, :template_not_populated} = Template.handle_instantiate(%{}, ctx)
    end
  end

  describe "handle_fork/2 — branches on kind_module" do
    test "unsupported kind → typed error" do
      ctx = ctx_with_slice(%{name: "x"}, %{kind_module: SomeOtherKind})

      assert {:error, {:template_fork_unsupported_for_kind, SomeOtherKind}} =
               Template.handle_fork(%{new_name: "demo2"}, ctx)
    end

    test "AgentTemplate with empty parent slice → :template_not_populated" do
      ctx =
        ctx_with_slice(nil, %{
          kind_module: AgentTemplate,
          self_uri: Ezagent.URI.new!("template://team-alpha/agent/demo")
        })

      assert {:error, :template_not_populated} =
               Template.handle_fork(%{new_name: "demo2"}, ctx)
    end

    test "missing new_name arg → {:error, {:missing_arg, :new_name}}" do
      ctx =
        ctx_with_slice(%{name: "demo"}, %{
          kind_module: AgentTemplate,
          self_uri: Ezagent.URI.new!("template://team-alpha/agent/demo")
        })

      assert {:error, {:missing_arg, :new_name}} = Template.handle_fork(%{}, ctx)
    end
  end

  describe "data_owner/1" do
    test "returns :any (workspace admin grants)" do
      assert Template.data_owner(:any) == :any
      assert Template.data_owner({:within_workspace, Ezagent.URI.new!("workspace://x")}) == :any
      assert Template.data_owner(Ezagent.URI.new!("template://ws/agent/n")) == :any
    end
  end
end
