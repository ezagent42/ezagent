defmodule Ezagent.PluginCodex.Template.CodexAgentGrantRestartTest do
  @moduledoc """
  #17 cascade PR-2 (§5.1) — cold-restart credential-grant re-validation gate for codex.
  A (re)start is a cascade boundary: an agent whose grant was revoked must NOT respawn
  holding stale creds. No-grant / active-grant agents proceed.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCodex.Template.CodexAgent
  alias Ezagent.Credential.GrantRow

  defp uniq, do: System.unique_integer([:positive])

  test "ensure_subprocess_alive fails loud when the agent's grant is revoked" do
    agent_uri = URI.new!("entity://team-a/agent/codex_revoked-#{uniq()}")
    on_exit(fn -> File.rm_rf(CodexAgent.agent_config_dir(agent_uri)) end)

    source_uri = "entity://team-a/agent/svc-#{uniq()}"
    {:ok, _} = Ezagent.SnapshotStore.write(source_uri, %{}, kind_type: :agent)

    {:ok, _g} =
      GrantRow.insert(%{
        agent_uri: URI.to_string(agent_uri),
        credential_source_uri: source_uri,
        approved_by: "entity://team-a/user/bob",
        approved_scope: source_uri,
        version: 1
      })

    {:ok, _} = GrantRow.revoke(URI.to_string(agent_uri))

    assert {:error, {:credential_grant_revoked, _}} =
             CodexAgent.ensure_subprocess_alive(agent_uri, %{"cwd" => "/tmp"})
  end

  test "an agent with NO grant (pre-cascade) is not blocked by the gate" do
    agent_uri = URI.new!("entity://team-a/agent/codex_nogrant-#{uniq()}")
    on_exit(fn -> File.rm_rf(CodexAgent.agent_config_dir(agent_uri)) end)

    result = CodexAgent.ensure_subprocess_alive(agent_uri, %{"cwd" => "/nonexistent-cwd"})
    refute match?({:error, {:credential_grant_revoked, _}}, result)
  end

  describe "grant revoked AFTER materialize, BEFORE launch (codex CRITICAL §5.1)" do
    setup do
      agent_uri = URI.new!("entity://team-a/agent/codex_toctou-#{uniq()}")
      target = CodexAgent.agent_config_dir(agent_uri)
      on_exit(fn -> File.rm_rf(target) end)

      source_uri = "entity://team-a/agent/svc-#{uniq()}"
      {:ok, _} = Ezagent.SnapshotStore.write(source_uri, %{}, kind_type: :agent)

      source_dir = Path.join(System.tmp_dir!(), "codex-cred-src-#{uniq()}")
      File.mkdir_p!(source_dir)
      File.write!(Path.join(source_dir, "auth.json"), "BOB-TOKEN")
      on_exit(fn -> File.rm_rf(source_dir) end)

      {:ok, _g} =
        GrantRow.insert(%{
          agent_uri: URI.to_string(agent_uri),
          credential_source_uri: source_uri,
          approved_by: "entity://team-a/user/bob",
          approved_scope: source_uri,
          version: 1
        })

      base = Path.join(System.tmp_dir!(), "codex-base-#{uniq()}")
      File.mkdir_p!(base)
      File.write!(Path.join(base, "config.toml"), "BASE")
      on_exit(fn -> File.rm_rf(base) end)

      tmpl = %{
        "config_dir" => base,
        "allocated_config_dir" => target,
        "cascade" => %{
          layer_dirs: [%{dir: base}],
          source_dir_for: fn _ -> {:ok, source_dir} end
        }
      }

      {:ok, agent_uri: agent_uri, target: target, tmpl: tmpl}
    end

    test "create_agent_config_dir returns the materialize-time grant version", ctx do
      assert {:ok, _target, {:grant, agent_uri_str, version}} =
               CodexAgent.create_agent_config_dir(ctx.agent_uri, ctx.tmpl)

      assert agent_uri_str == URI.to_string(ctx.agent_uri)
      assert version == 1
      assert File.exists?(Path.join(ctx.target, ".ezagent-config-complete"))
      # §D6: secret pulled from the source
      assert File.read!(Path.join(ctx.target, "auth.json")) == "BOB-TOKEN"
    end

    test "the pre-launch gate aborts when the grant is revoked after materialize", ctx do
      assert {:ok, _target, {:grant, agent_uri_str, version}} =
               CodexAgent.create_agent_config_dir(ctx.agent_uri, ctx.tmpl)

      {:ok, _} = GrantRow.revoke(agent_uri_str)

      # the exact GrantRow call spawn_for_codex's pre-launch gate makes with the captured
      # version → aborts the sidecar/PTY launch (nothing launches with the revoked secret).
      assert {:error, :grant_changed} = GrantRow.revalidate_version!(agent_uri_str, version)

      # the abort path clears the just-materialized config_dir (rollback_agent_config_dir
      # removes agent_config_dir/1) — prove that targets the materialized dir.
      assert CodexAgent.agent_config_dir(ctx.agent_uri) == ctx.target
    end
  end
end
