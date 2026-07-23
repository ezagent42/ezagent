defmodule Ezagent.Entity.AgentTemplateTest do
  @moduledoc """
  Phase 7 PR 37 — AgentTemplate Kind structural tests.

  These tests pin the Kind contract surface (callbacks, persistence,
  behaviors) so future refactors don't drift the type. End-to-end
  spawn + slice population is covered by Phase 7 PR 40 (`Ezagent.Entity.Agent.spawn/4`
  spawn-from-template flow) which exercises the spawn path.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Entity.AgentTemplate

  setup_all do
    # Register the plugins' exact declarations.  A reduced test-only declaration
    # poisons the global registry: when a later test boots the real plugin its
    # idempotency check correctly rejects the conflicting flavor definition.
    for plugin <- [
          EzagentPluginCc.Application,
          EzagentPluginCurlAgent.Application,
          EzagentPluginCodex.Application
        ],
        declaration <- plugin.agent_flavors() do
      :ok = Ezagent.AgentFlavorRegistry.register(declaration)
    end

    :ok
  end

  test "type_name/0 returns :agent_template" do
    assert AgentTemplate.type_name() == :agent_template
  end

  test "behaviors/0 includes Identity (caps + grant policy live on slice)" do
    behaviors = AgentTemplate.behaviors()

    assert Ezagent.ActionSet.Identity in behaviors,
           "AgentTemplate must carry Identity behavior so default_caps + slice " <>
             "edit can use the existing identity dispatch path"
  end

  test "behaviors/0 includes Behavior.Template (Phase 7 completion PR-1 — content slice)" do
    assert Ezagent.ActionSet.Template in AgentTemplate.behaviors(),
           "AgentTemplate must carry Behavior.Template so the :template content " <>
             "slice has dispatchable read/write/instantiate actions (SPEC §1.0)"
  end

  test "persistence/0 is {:snapshot, :on_change} — config is durable" do
    assert AgentTemplate.persistence() == {:snapshot, :on_change},
           "AgentTemplate slice must survive phx restart; orchestrator's " <>
             "list_templates depends on persisted templates being there"
  end

  test "Ezagent.Kind behaviour callbacks all implemented" do
    # Spot-check by spawning a Kind.Server and asserting it accepts the
    # AgentTemplate as the kind module argument shape.
    callbacks_ok =
      [:type_name, :behaviors, :persistence]
      |> Enum.all?(fn cb -> function_exported?(AgentTemplate, cb, 0) end)

    assert callbacks_ok,
           "AgentTemplate must implement all three @impl Ezagent.Kind callbacks: " <>
             "type_name/0, behaviors/0, persistence/0"
  end

  describe "to_template_data/2 (Phase 7 completion PR-1, SPEC §1.5 (b))" do
    @instance_uri URI.new!("entity://team-alpha/agent/cc_worker-1")

    test "round-trips a cc-flavored content map to the cc.agent data shape" do
      content = %{
        name: "worker",
        description: "a worker",
        flavor: "cc",
        project_cwd: "/tmp/proj"
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @instance_uri)
      assert data["class"] == "cc.agent"
      assert data["agent_uri"] == "entity://team-alpha/agent/cc_worker-1"
      assert data["cwd"] == "/tmp/proj"
      # The optional keys are absent when the content sets none —
      # so the legacy 3-key cc.agent form still validates. config_dir is
      # universal now but still dropped when nil.
      refute Map.has_key?(data, "operator_settings_path")
      refute Map.has_key?(data, "config_dir")
    end

    test "threads the optional sandbox keys when present (config_dir universal)" do
      content = %{
        name: "worker",
        flavor: "cc",
        project_cwd: "/tmp/proj",
        settings_path: "/sandbox/settings.json",
        mcp_config_path: "/sandbox/mcp.json",
        config_dir: "/sandbox/.claude",
        api_key_helper: "/sandbox/key.sh"
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @instance_uri)
      assert data["operator_settings_path"] == "/sandbox/settings.json"
      assert data["operator_mcp_config_path"] == "/sandbox/mcp.json"
      # config_dir promotion (Allen 2026-06-03): emitted in the UNIVERSAL
      # base under the flavor-neutral "config_dir" key — NOT a cc-named
      # "claude_config_dir" key.
      assert data["config_dir"] == "/sandbox/.claude"
      refute Map.has_key?(data, "claude_config_dir")
      assert data["api_key_helper"] == "/sandbox/key.sh"
    end

    test "errors when project_cwd is missing" do
      content = %{name: "w", flavor: "cc"}

      assert {:error, :missing_project_cwd} =
               AgentTemplate.to_template_data(content, @instance_uri)
    end

    # PR-2 (domain.agent): the template carries TWO distinct, explicitly-named
    # intents — `project_cwd` (universal: where the agent runs / cd's into,
    # → "cwd") and `config_dir` (universal: the per-agent config-home INPUT,
    # → "config_dir"). They map to DIFFERENT, flavor-neutral data keys; one
    # is not the other. config_dir promotion (Allen 2026-06-03): both are
    # universal; the neutral "config_dir" key is NOT cc-named.
    test "project_cwd and config_dir are distinct intents → distinct data keys" do
      content = %{
        name: "w",
        flavor: "cc",
        project_cwd: "/tmp/project",
        config_dir: "/tmp/sandbox/.claude"
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @instance_uri)
      assert data["cwd"] == "/tmp/project", "project_cwd drives the project cwd data key"

      assert data["config_dir"] == "/tmp/sandbox/.claude",
             "config_dir drives the universal config-dir input data key"

      refute data["cwd"] == data["config_dir"],
             "the two intents must NOT collapse to the same path"
    end

    test "errors when flavor is missing" do
      content = %{name: "w", project_cwd: "/tmp"}

      assert {:error, :missing_flavor} =
               AgentTemplate.to_template_data(content, @instance_uri)
    end

    test "the data map is a string-keyed map the cc Template Class accepts" do
      content = %{name: "w", flavor: "cc", project_cwd: "/tmp"}
      {:ok, data} = AgentTemplate.to_template_data(content, @instance_uri)

      assert :ok = Ezagent.PluginCc.Template.CcAgent.validate(data)
    end
  end

  # SPEC 2026-06-01-flavor-generic-template-data (approach B): core no
  # longer hardcodes cc's field set — each flavor's Template Class declares
  # its content fields via template_data_extra/1, so orchestrator-spawned
  # curl/codex workers carry their provider/model config (pre-fix dropped).
  describe "to_template_data/2 is flavor-generic (SPEC 2026-06-01)" do
    # The agent URI prefix must match the flavor (each flavor's validate/1
    # enforces `<flavor>_<name>`).
    @curl_uri URI.new!("entity://team-alpha/agent/curl_w-gen")
    @codex_uri URI.new!("entity://team-alpha/agent/codex_w-gen")
    @cc_uri URI.new!("entity://team-alpha/agent/cc_w-gen")

    test "threads curl provider/api_url/model (pre-fix these were dropped)" do
      content = %{
        flavor: "curl",
        project_cwd: "/tmp/c",
        provider: "deepseek",
        api_url: "https://api.deepseek.com/chat/completions",
        model: "deepseek-chat",
        system_prompt: "",
        max_history: 20
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @curl_uri)
      assert data["class"] == "curl.agent"
      assert data["provider"] == "deepseek"
      assert data["api_url"] == "https://api.deepseek.com/chat/completions"
      assert data["model"] == "deepseek-chat"
    end

    test "manifest-resolved transient content compiles through the flavor callback before validation" do
      content = %{
        flavor: "curl",
        project_cwd: "/tmp/c",
        agent_manifest_resolved: %{instructions: "Fast ack only.", skills: []},
        agent_manifest_params: %{
          "provider" => "deepseek",
          "api_url" => "https://api.deepseek.com/chat/completions",
          "model" => "deepseek-chat"
        }
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @curl_uri)
      assert data["class"] == "curl.agent"
      assert data["provider"] == "deepseek"
      assert data["system_prompt"] == "Fast ack only."
    end

    test "manifest-resolved cc content emits one MCP entry per non-optional tool" do
      content = %{
        flavor: "cc",
        project_cwd: "/tmp/c",
        agent_manifest_resolved: %{
          instructions: "Coordinate.",
          skills: [],
          tools: [
            %{
              name: "notify_owner",
              type: :action,
              action: "entity://system/user/admin?action=notifications.notify",
              caps: [%{"kind" => "user"}],
              optional: false
            },
            %{
              name: "add_operator",
              type: :participant,
              ref: "entity://system/user/operator",
              role_name: "operator",
              optional: false
            }
          ]
        },
        agent_manifest_params: %{}
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @cc_uri)

      assert data["manifest_tools"] == content.agent_manifest_resolved.tools

      assert %{"notify_owner" => action_entry, "add_operator" => participant_entry} =
               data["manifest_mcp_servers"]

      assert action_entry["ctx_caps"] == []
      assert action_entry["dispatch"] == "entity://system/user/admin?action=notifications.notify"
      assert participant_entry["tool_type"] == "participant"
    end

    test "tool-less curl compile rejects non-optional manifest tools" do
      content = %{
        flavor: "curl",
        project_cwd: "/tmp/c",
        agent_manifest_resolved: %{
          instructions: "Fast ack only.",
          skills: [],
          tools: [
            %{
              name: "notify_owner",
              type: :action,
              action: "entity://system/user/admin?action=notifications.notify",
              caps: [%{"kind" => "user"}],
              optional: false
            }
          ]
        },
        agent_manifest_params: %{
          "provider" => "deepseek",
          "api_url" => "https://api.deepseek.com/chat/completions",
          "model" => "deepseek-chat"
        }
      }

      assert {:error, {:tools_unsupported, "curl", ["notify_owner"]}} =
               AgentTemplate.to_template_data(content, @curl_uri)
    end

    test "tool-less curl compile drops optional manifest tools explicitly" do
      content = %{
        flavor: "curl",
        project_cwd: "/tmp/c",
        agent_manifest_resolved: %{
          instructions: "Fast ack only.",
          skills: [],
          tools: [
            %{
              name: "notify_owner",
              type: :action,
              action: "entity://system/user/admin?action=notifications.notify",
              caps: [%{"kind" => "user"}],
              optional: true
            }
          ]
        },
        agent_manifest_params: %{
          "provider" => "deepseek",
          "api_url" => "https://api.deepseek.com/chat/completions",
          "model" => "deepseek-chat"
        }
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @curl_uri)
      refute Map.has_key?(data, "manifest_mcp_servers")
      refute Map.has_key?(data, "manifest_tools")
    end

    test "threads codex model/approval/sandbox" do
      content = %{
        flavor: "codex",
        project_cwd: "/tmp/x",
        model: "gpt-5-codex",
        approval_policy: "never",
        sandbox: "workspace-write"
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @codex_uri)
      assert data["class"] == "codex.agent"
      assert data["model"] == "gpt-5-codex"
      assert data["approval_policy"] == "never"
      assert data["sandbox"] == "workspace-write"
    end

    test "fail-fast: curl content missing provider → {:error, {:invalid_template_data, _}}" do
      content = %{
        flavor: "curl",
        project_cwd: "/tmp/c",
        api_url: "https://api.deepseek.com/chat/completions",
        model: "deepseek-chat"
      }

      assert {:error, {:invalid_template_data, :missing_provider}} =
               AgentTemplate.to_template_data(content, @curl_uri),
             "a curl template missing the required provider must fail loud, NOT " <>
               "spawn a nil-config worker"
    end

    test "string-keyed (post-JSON) curl content threads the same" do
      content = %{
        "flavor" => "curl",
        "project_cwd" => "/tmp/c",
        "provider" => "deepseek",
        "api_url" => "https://api.deepseek.com/chat/completions",
        "model" => "deepseek-chat"
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @curl_uri)
      assert data["provider"] == "deepseek"
      assert data["model"] == "deepseek-chat"
    end

    test "cc still threads its fields (regression) — config_dir universal, role cc-owned" do
      content = %{
        flavor: "cc",
        project_cwd: "/tmp/proj",
        config_dir: "/sandbox/.claude",
        role: "orchestrator"
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @cc_uri)
      assert data["class"] == "cc.agent"
      assert data["cwd"] == "/tmp/proj"
      # config_dir promotion (Allen 2026-06-03): config_dir is emitted in the
      # UNIVERSAL base under the neutral "config_dir" key (cc reads it +
      # applies claude semantics). role stays a cc flavor extra.
      assert data["config_dir"] == "/sandbox/.claude"
      refute Map.has_key?(data, "claude_config_dir")
      assert data["role"] == "orchestrator"
    end
  end

  # config_dir promotion (Allen 2026-06-03): the CONCEPT "every agent has a
  # per-agent config home directory" is UNIVERSAL. The universal base of
  # `to_template_data/2` emits a flavor-NEUTRAL `"config_dir"` data key for
  # EVERY flavor — not just cc. Only the CONTENTS / file-format of that dir
  # are flavor-specific (cc reads it as CLAUDE_CONFIG_DIR; curl/codex/echo
  # may use it per their own format).
  describe "config_dir is UNIVERSAL (Allen 2026-06-03)" do
    @curl_uri URI.new!("entity://team-alpha/agent/curl_cfg")
    @py_uri URI.new!("entity://team-alpha/agent/py_cfg")
    @cc_uri URI.new!("entity://team-alpha/agent/cc_cfg")

    test "a non-cc (curl) flavor's template ALSO emits the universal config_dir key" do
      content = %{
        flavor: "curl",
        project_cwd: "/tmp/c",
        config_dir: "/tmp/curl-agent/config",
        provider: "deepseek",
        api_url: "https://api.deepseek.com/chat/completions",
        model: "deepseek-chat"
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @curl_uri)
      assert data["class"] == "curl.agent"

      # The universal, flavor-neutral config_dir is present for curl too —
      # this is the whole point of the promotion. It is NOT cc-named.
      assert data["config_dir"] == "/tmp/curl-agent/config",
             "config_dir is universal — every flavor's template emits it"

      refute Map.has_key?(data, "claude_config_dir"),
             "the universal key is neutral; no cc-specific name leaks into curl data"
    end

    test "a non-cc (py) flavor's template ALSO emits the universal config_dir key" do
      content = %{
        flavor: "py",
        project_cwd: "/tmp/e",
        config_dir: "/tmp/py-agent/config",
        script: "print('hi')"
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @py_uri)
      assert data["class"] == "py.agent"
      assert data["config_dir"] == "/tmp/py-agent/config"
      refute Map.has_key?(data, "claude_config_dir")
    end

    test "config_dir is dropped (not emitted) when nil — for cc AND non-cc flavors" do
      cc = %{flavor: "cc", project_cwd: "/tmp/p"}

      curl = %{
        flavor: "curl",
        project_cwd: "/tmp/c",
        provider: "deepseek",
        api_url: "https://x",
        model: "m"
      }

      assert {:ok, cc_data} = AgentTemplate.to_template_data(cc, @cc_uri)
      assert {:ok, curl_data} = AgentTemplate.to_template_data(curl, @curl_uri)
      refute Map.has_key?(cc_data, "config_dir")
      refute Map.has_key?(curl_data, "config_dir")
    end

    test "a malformed config_dir fails loud — NOT silently dropped (codex P2)" do
      # A present-but-malformed config_dir (non-binary or "") must fail loud,
      # not be silently omitted (which would spawn the agent without its
      # isolated config dir). feedback_let_it_crash_no_workarounds.
      bad_int = %{flavor: "cc", project_cwd: "/tmp/p", config_dir: 123}
      bad_empty = %{flavor: "cc", project_cwd: "/tmp/p", config_dir: ""}

      assert {:error, {:invalid_config_dir, 123}} =
               AgentTemplate.to_template_data(bad_int, @cc_uri)

      assert {:error, {:invalid_config_dir, ""}} =
               AgentTemplate.to_template_data(bad_empty, @cc_uri)
    end

    test "a stale claude_config_dir CONTENT field fails loud (codex P2)" do
      # A content map that uses the new project_cwd but still carries the OLD
      # claude_config_dir content field must fail loud — NOT be silently
      # ignored (which would spawn the cc agent without its CLAUDE_CONFIG_DIR).
      stale_atom = %{flavor: "cc", project_cwd: "/tmp/p", claude_config_dir: "/old/.claude"}

      stale_str = %{
        "flavor" => "cc",
        "project_cwd" => "/tmp/p",
        "claude_config_dir" => "/old/.claude"
      }

      assert {:error, {:stale_config_dir_field, :claude_config_dir, _}} =
               AgentTemplate.to_template_data(stale_atom, @cc_uri)

      assert {:error, {:stale_config_dir_field, :claude_config_dir, _}} =
               AgentTemplate.to_template_data(stale_str, @cc_uri)
    end

    test "the cc Template Class accepts the universal config_dir data key" do
      # The data the cc Template Class receives carries the neutral
      # "config_dir" key; cc's validate/1 accepts it (cc reads it for its
      # CLAUDE_CONFIG_DIR semantics — the consume path itself is unit-tested
      # in apps/ezagent_plugin_cc/test).
      content = %{flavor: "cc", project_cwd: "/tmp/p", config_dir: "/tmp/ref/.claude"}
      assert {:ok, data} = AgentTemplate.to_template_data(content, @cc_uri)
      assert data["config_dir"] == "/tmp/ref/.claude"
      assert :ok = Ezagent.PluginCc.Template.CcAgent.validate(data)
    end
  end

  # PR-6 (domain.agent) — DOMAIN-owned desired skills/caps. These are
  # universal (flavor-agnostic) content fields the DOMAIN declares; they
  # ride into the Template-Class data map so a flavor's instantiate/3 can
  # place skills, and the domain spawn path can grant caps. (The actual
  # grant + live re-copy is the re-materialization seam shared with PR-5's
  # reconfigure — see docs/notes/pr6-desired-skills-caps.md.)
  describe "to_template_data/2 threads desired_skills/desired_caps (PR-6)" do
    @cc_uri URI.new!("entity://team-alpha/agent/cc_w-pr6")

    test "threads desired_skills into the data map when present" do
      content = %{
        flavor: "cc",
        project_cwd: "/tmp/proj",
        desired_skills: ["ezagent-developer", "elixir-phoenix-helper"]
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @cc_uri)
      assert data["desired_skills"] == ["ezagent-developer", "elixir-phoenix-helper"]
    end

    test "threads desired_caps into the data map when present" do
      cap = %Ezagent.Capability{
        kind: :session,
        behavior: Ezagent.ActionSet.Session,
        action: :any,
        instance: :any,
        workspace_uri: URI.new!("workspace://team-alpha"),
        granted_by: URI.new!("entity://team-alpha/user/admin"),
        granted_at: DateTime.utc_now()
      }

      content = %{
        flavor: "cc",
        project_cwd: "/tmp/proj",
        desired_caps: [cap]
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @cc_uri)
      assert data["desired_caps"] == [cap]
    end

    test "omits desired_skills/desired_caps when absent (no empty keys)" do
      content = %{flavor: "cc", project_cwd: "/tmp/proj"}

      assert {:ok, data} = AgentTemplate.to_template_data(content, @cc_uri)
      refute Map.has_key?(data, "desired_skills")
      refute Map.has_key?(data, "desired_caps")
    end

    test "reads string-keyed desired_skills (post-JSON snapshot roundtrip)" do
      content = %{
        "flavor" => "cc",
        "project_cwd" => "/tmp/proj",
        "desired_skills" => ["s1"]
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @cc_uri)
      assert data["desired_skills"] == ["s1"]
    end
  end

  describe "to_template_data/2 activates cascade materialization inputs (#17 PR-3)" do
    @cc_uri URI.new!("entity://team-alpha/agent/cc_cascade-pr3")

    test "threads explicit cascade layer_dirs and source_dir_for into Template Class data" do
      source_dir_for = fn
        "entity://team-alpha/agent/alice-source" -> {:ok, "/tmp/alice-source"}
      end

      content = %{
        flavor: "cc",
        project_cwd: "/tmp/proj",
        config_dir: "/tmp/reference-config",
        cascade: %{
          layer_dirs: [
            %{dir: "/tmp/workspace-layer", protected: ["hooks/policy.sh"], mandatory: []},
            %{dir: "/tmp/user-layer", protected: [], mandatory: []}
          ],
          source_dir_for: source_dir_for
        }
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @cc_uri)
      assert %{} = cascade = data["cascade"]
      assert cascade.layer_dirs == content.cascade.layer_dirs
      assert cascade.source_dir_for == source_dir_for
    end

    test "malformed cascade content fails loud instead of reaching the Template Class" do
      content = %{
        flavor: "cc",
        project_cwd: "/tmp/proj",
        cascade: "not-a-map"
      }

      assert {:error, {:invalid_cascade, "not-a-map"}} =
               AgentTemplate.to_template_data(content, @cc_uri)
    end
  end
end
