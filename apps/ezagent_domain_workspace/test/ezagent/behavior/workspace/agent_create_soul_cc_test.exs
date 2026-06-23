defmodule Ezagent.Behavior.Workspace.AgentCreateSoulCcTest do
  @moduledoc """
  B2: when a cc create carries `soul:`, the create path routes through the
  AgentManifest content path, so the soul reaches `claude_md` in the compiled
  template data.

  Tests assert at the unit level — directly on the helper that builds the tmpl
  map (via the public `__file_flavor_template_for_test__` accessor + the new
  `__manifest_tmpl_for_test__` accessor) and on `AgentManifest.to_template_content/4`
  output — so no PTY spawn or DB is required for the soul→claude_md path.

  Regression coverage asserts the soul-ABSENT cc path still uses the bare
  `file_flavor_template` (no `agent_manifest_resolved`).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.AgentManifest
  alias Ezagent.Behavior.Workspace.AgentCreate

  # A real agent URI + cwd needed for per_agent_config_dir calls.
  @workspace_name "soul-cc-test"
  @agent_uri URI.new!("entity://#{@workspace_name}/agent/soul-cc-alice")
  @cwd "/tmp"
  @soul "你是前台导购助手，简短友好地回答顾客问题。"

  describe "soul-present: AgentManifest.to_template_content/4 output carries instructions" do
    test "to_template_content produces agent_manifest_resolved.instructions from soul" do
      manifest = %AgentManifest{
        name: "soul-cc-alice",
        soul: @soul,
        skills: [],
        tools: [],
        caps: [],
        lifecycle: :persistent,
        executor: %{
          flavor: ["cc"],
          params: %{project_cwd: @cwd},
          fallback: nil,
          on_exhausted: :notify_orchestrator
        }
      }

      assert {:ok, content} = AgentManifest.to_template_content(manifest, "cc", %{})

      # The resolved field carries the soul as :instructions
      resolved = content[:agent_manifest_resolved]
      assert is_map(resolved)
      assert resolved[:instructions] == @soul
    end

    test "compile_cc_agent_data turns agent_manifest_resolved.instructions into claude_md" do
      manifest = %AgentManifest{
        name: "soul-cc-alice",
        soul: @soul,
        skills: [],
        tools: [],
        caps: [],
        lifecycle: :persistent,
        executor: %{
          flavor: ["cc"],
          params: %{project_cwd: @cwd},
          fallback: nil,
          on_exhausted: :notify_orchestrator
        }
      }

      {:ok, content} = AgentManifest.to_template_content(manifest, "cc", %{})
      resolved = content[:agent_manifest_resolved]
      params = content[:agent_manifest_params] || %{}

      assert {:ok, data} =
               Ezagent.Kind.Template.compile_cc_agent_data(
                 resolved,
                 params,
                 fn extra -> extra end
               )

      # The soul was placed into claude_md
      assert data["claude_md"] == @soul
    end
  end

  describe "B2 seam: __manifest_tmpl_for_test__/4 builds tmpl with agent_manifest_resolved" do
    test "soul-present cc tmpl carries agent_manifest_resolved.instructions" do
      # B2 adds this test accessor. RED until B2 is implemented.
      tmpl = AgentCreate.__manifest_tmpl_for_test__(@agent_uri, @cwd, @soul)

      # Must carry the soul as agent_manifest_resolved.instructions
      resolved = Map.get(tmpl, :agent_manifest_resolved)
      assert is_map(resolved), "expected :agent_manifest_resolved in tmpl, got: #{inspect(tmpl)}"
      assert resolved[:instructions] == @soul
    end

    test "soul-present cc tmpl still has class, flavor, project_cwd, config_dir" do
      tmpl = AgentCreate.__manifest_tmpl_for_test__(@agent_uri, @cwd, @soul)

      # Must preserve base file-flavor keys needed for validate + cascade
      assert tmpl["class"] == "cc.agent"
      assert tmpl["flavor"] == "cc"
      assert tmpl["project_cwd"] == @cwd
      assert is_binary(tmpl["config_dir"]) and tmpl["config_dir"] != ""
    end
  end

  describe "soul-absent cc path: unchanged (no agent_manifest_resolved)" do
    test "bare file_flavor_template has no agent_manifest_resolved" do
      tmpl = AgentCreate.__file_flavor_template_for_test__("cc", "cc.agent", @agent_uri, @cwd)

      # Must NOT carry agent_manifest_resolved — soul-absent path is unchanged
      refute Map.has_key?(tmpl, :agent_manifest_resolved),
             "soul-absent path must not embed agent_manifest_resolved"
    end
  end

  describe "soul render failure: no silent personaless agent (invariant #9)" do
    test "__manifest_tmpl_for_test__/3 returns {:error, {:soul_render_failed, _}} when render fails" do
      # A soul template with a slot reference that is NOT provided in slots ({})
      # forces AgentManifest.render/2 to return {:error, {:missing_slot, _}}.
      # manifest_cc_tmpl/3 must propagate that as {:error, {:soul_render_failed, _}}
      # rather than silently falling back to the bare template.
      soul_with_missing_slot = "You are {{missing_slot}} the assistant."

      assert {:error, {:soul_render_failed, _reason}} =
               AgentCreate.__manifest_tmpl_for_test__(@agent_uri, @cwd, soul_with_missing_slot)
    end

    test "__manifest_tmpl_for_test__/3 does NOT return a bare tmpl map on render failure" do
      # Verify the old fallback path is gone: the result must NOT be a map
      # (which would mean a personaless agent was silently created).
      soul_with_missing_slot = "You are {{undefined_slot}} assistant."

      result = AgentCreate.__manifest_tmpl_for_test__(@agent_uri, @cwd, soul_with_missing_slot)

      refute is_map(result),
             "render failure must NOT fall back to a bare tmpl map; got: #{inspect(result)}"
    end
  end

  describe "to_cascade_content pass-through: agent_manifest_resolved survives" do
    test "to_cascade_content keeps agent_manifest_resolved when present" do
      # Build a soul-enriched tmpl (same as B2 implementation does)
      manifest = %AgentManifest{
        name: "soul-cc-alice",
        soul: @soul,
        skills: [],
        tools: [],
        caps: [],
        lifecycle: :persistent,
        executor: %{
          flavor: ["cc"],
          params: %{project_cwd: @cwd},
          fallback: nil,
          on_exhausted: :notify_orchestrator
        }
      }

      {:ok, manifest_content} = AgentManifest.to_template_content(manifest, "cc", %{})

      # Build base tmpl and merge manifest_resolved into it (simulating B2 impl)
      base_tmpl =
        AgentCreate.__file_flavor_template_for_test__("cc", "cc.agent", @agent_uri, @cwd)

      enriched_tmpl =
        Map.put(base_tmpl, :agent_manifest_resolved, manifest_content[:agent_manifest_resolved])

      # B2 extends to_cascade_content to pass agent_manifest_resolved through.
      # RED until B2 is implemented.
      assert {:ok, cascade_content} = AgentCreate.__cascade_content_for_test__(enriched_tmpl)
      resolved = Map.get(cascade_content, :agent_manifest_resolved)

      assert is_map(resolved),
             "to_cascade_content must pass :agent_manifest_resolved through; got content: #{inspect(cascade_content)}"

      assert resolved[:instructions] == @soul
    end
  end
end
