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

  describe "grant-revoke rollback surfaces cleanup failure (codex H2 — FINDING 2)" do
    test "grant-revoked at launch removes the materialized config_dir" do
      agent_uri = URI.new!("entity://team-a/agent/codex_cleanup-#{uniq()}")
      dir = CodexAgent.agent_config_dir(agent_uri)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "auth.json"), "SECRET")
      on_exit(fn -> File.rm_rf(dir) end)
      assert File.exists?(dir)

      reason = {:grant_changed_before_launch, URI.to_string(agent_uri)}
      assert {:error, ^reason} = CodexAgent.handle_spawn_failure(agent_uri, reason)

      refute File.exists?(dir)
    end

    test "cleanup failure → composite blocking error (not :ok, not only grant-change)" do
      agent_uri = URI.new!("entity://team-a/agent/codex_cleanupfail-#{uniq()}")
      dir = CodexAgent.agent_config_dir(agent_uri)
      ro_sub = Path.join(dir, "sub")
      File.mkdir_p!(ro_sub)
      File.write!(Path.join(ro_sub, "f"), "X")
      File.write!(Path.join(dir, "auth.json"), "SECRET")
      File.chmod!(ro_sub, 0o500)
      on_exit(fn -> File.chmod(ro_sub, 0o700) && File.rm_rf(dir) end)

      reason = {:grant_changed_before_launch, URI.to_string(agent_uri)}
      result = CodexAgent.handle_spawn_failure(agent_uri, reason)

      File.chmod!(ro_sub, 0o700)

      assert {:error, {:grant_revoked_cleanup_failed, ^agent_uri, _cleanup_reason}} = result
      refute match?({:error, {:grant_changed_before_launch, _}}, result)
    end
  end

  describe "recover_orphaned error at materialize ENTRY (codex H)" do
    # Mirror of the cc test: when the crash-mid-swap self-heal at materialize entry detects a
    # leftover known-good `.bak` + a missing/partial target but CANNOT restore it, the entry
    # MUST FAIL LOUD rather than proceed to a fresh materialize (which could clobber the only
    # good copy).
    test "materialize ENTRY aborts when recover_orphaned cannot restore" do
      agent_uri = URI.new!("entity://team-a/agent/codex_recover-#{uniq()}")

      # Own the parent so we can make it read-only without touching the shared config root.
      parent = Path.join(System.tmp_dir!(), "codex-ro-parent-#{uniq()}")
      File.mkdir_p!(parent)
      on_exit(fn -> File.chmod(parent, 0o700) && File.rm_rf(parent) end)
      target = Path.join(parent, "cfg")

      # Crash mid-swap: target ABSENT, known-good prior tree in a sibling `.bak`.
      bak = "#{target}.bak-#{uniq()}"
      File.mkdir_p!(bak)
      File.write!(Path.join(bak, "auth.json"), "PRIOR-TOKEN")
      refute File.exists?(target)

      ref = Path.join(System.tmp_dir!(), "codex-ref-#{uniq()}")
      File.mkdir_p!(ref)
      File.write!(Path.join(ref, "config.toml"), "NEW")
      on_exit(fn -> File.rm_rf(ref) end)

      # Read-only parent → recover_orphaned's restore `File.rename(bak, target)` fails.
      File.chmod!(parent, 0o500)

      tmpl = %{"config_dir" => ref, "allocated_config_dir" => target}

      result = CodexAgent.create_agent_config_dir(agent_uri, tmpl)

      File.chmod!(parent, 0o700)

      assert {:error, {:config_dir_recover_failed, {:recover_restore_failed, ^bak, _}}} = result

      # CRITICAL: the only known-good prior tree (the `.bak`) is preserved.
      assert File.exists?(bak)
      assert File.read!(Path.join(bak, "auth.json")) == "PRIOR-TOKEN"
    end
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
      assert {:ok, _target, {:grant, agent_uri_str, incarnation_id, version}} =
               CodexAgent.create_agent_config_dir(ctx.agent_uri, ctx.tmpl)

      assert agent_uri_str == URI.to_string(ctx.agent_uri)
      assert version == 1
      assert is_binary(incarnation_id)
      assert File.exists?(Path.join(ctx.target, ".ezagent-config-complete"))
      # §D6: secret pulled from the source
      assert File.read!(Path.join(ctx.target, "auth.json")) == "BOB-TOKEN"
    end

    test "the pre-launch gate aborts when the grant is revoked after materialize", ctx do
      assert {:ok, _target, {:grant, agent_uri_str, incarnation_id, version}} =
               CodexAgent.create_agent_config_dir(ctx.agent_uri, ctx.tmpl)

      {:ok, _} = GrantRow.revoke(agent_uri_str)

      # the exact GrantRow call spawn_for_codex's pre-launch gate makes with the captured
      # version → aborts the sidecar/PTY launch (nothing launches with the revoked secret).
      assert {:error, :grant_changed} = GrantRow.revalidate_version!(agent_uri_str, incarnation_id, version)

      # the abort path clears the just-materialized config_dir (rollback_agent_config_dir
      # removes agent_config_dir/1) — prove that targets the materialized dir.
      assert CodexAgent.agent_config_dir(ctx.agent_uri) == ctx.target
    end
  end
end
