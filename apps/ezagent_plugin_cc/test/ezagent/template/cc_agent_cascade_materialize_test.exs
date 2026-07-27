defmodule Ezagent.PluginCc.Template.CcAgentCascadeMaterializeTest do
  @moduledoc """
  #17 cascade PR-2 — end-to-end wiring of the layered cascade materialize through the cc
  Template Class' `create_agent_config_dir/2` (spec §D4 layer-merge + §D6 secret-only copy
  + §5.1 grant TOCTOU + §7 atomic-replace). Proves the plugin delegates to the core
  `Ezagent.Agent.Materializer` correctly when the create chokepoint (PR-3) supplies the
  `"cascade"` inputs, while the single-reference path stays backward-compatible.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCc.Template.CcAgent
  alias Ezagent.Credential.GrantRow

  defp uniq, do: System.unique_integer([:positive])

  defp tmp(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write!(dir, rel, contents) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  setup do
    agent_uri = URI.new!("entity://team-a/agent/cc_cascade-#{uniq()}")
    target = CcAgent.agent_config_dir(agent_uri)
    on_exit(fn -> File.rm_rf(target) end)

    source_uri = "entity://team-a/agent/alice-base-#{uniq()}"
    {:ok, _} = Ezagent.SnapshotStore.write(source_uri, %{}, kind_type: :agent)

    source_dir = tmp("cc-cred-src")
    File.write!(Path.join(source_dir, ".credentials.json"), "ALICE-TOKEN")
    # config files at the source MUST NOT be pulled (§D6).
    File.write!(Path.join(source_dir, "settings.json"), "SOURCE-SETTINGS")

    {:ok, _g} =
      GrantRow.insert(%{
        agent_uri: URI.to_string(agent_uri),
        credential_source_uri: source_uri,
        approved_by: "entity://team-a/user/alice",
        approved_scope: source_uri,
        version: 1
      })

    {:ok, agent_uri: agent_uri, target: target, source_uri: source_uri, source_dir: source_dir}
  end

  defp cascade_tmpl(ctx, layer_dirs) do
    %{
      # required by create_agent_config_dir's outer guards (a non-empty ref + target).
      "config_dir" => List.first(layer_dirs).dir,
      "allocated_config_dir" => ctx.target,
      "cascade" => %{
        layer_dirs: layer_dirs,
        source_dir_for: fn _source_uri -> {:ok, ctx.source_dir} end
      }
    }
  end

  test "merges layers + copies ONLY the secret from the source + atomic-commits", ctx do
    base = tmp("cc-base")
    user = tmp("cc-user")
    write!(base, "settings.json", "BASE")
    write!(base, "plugins/base_only.json", "B")
    write!(user, "settings.json", "USER")
    write!(user, "plugins/user_only.json", "U")

    tmpl = cascade_tmpl(ctx, [%{dir: base}, %{dir: user}])

    assert {:ok, target, {:grant, _, _, _}} = CcAgent.create_agent_config_dir(ctx.agent_uri, tmpl)
    assert target == ctx.target

    # whole-file-replace: user (higher) wins
    assert File.read!(Path.join(target, "settings.json")) == "USER"
    # directory-union
    assert File.read!(Path.join(target, "plugins/base_only.json")) == "B"
    assert File.read!(Path.join(target, "plugins/user_only.json")) == "U"
    # §D6: secret copied from the source
    assert File.read!(Path.join(target, ".credentials.json")) == "ALICE-TOKEN"
    # §D6: the source's CONFIG file was NOT pulled (settings.json is the merged USER one)
    refute File.read!(Path.join(target, "settings.json")) == "SOURCE-SETTINGS"
    # completion marker present
    assert File.exists?(Path.join(target, ".ezagent-config-complete"))
    # no orphan staging
    assert ctx.target
           |> Path.dirname()
           |> File.ls!()
           |> Enum.filter(&String.contains?(&1, ".staging-")) ==
             []
  end

  test "revoke-mid-start (TOCTOU) aborts before the dir is committed", ctx do
    base = tmp("cc-base")
    write!(base, "settings.json", "BASE")

    # Inject the revoke during source resolution (after fetch read v1, before revalidate).
    tmpl = %{
      "config_dir" => base,
      "allocated_config_dir" => ctx.target,
      "cascade" => %{
        layer_dirs: [%{dir: base}],
        source_dir_for: fn _ ->
          {:ok, _} = GrantRow.revoke(URI.to_string(ctx.agent_uri))
          {:ok, ctx.source_dir}
        end
      }
    }

    assert {:error, {:cascade_materialize_failed, :grant_changed}} =
             CcAgent.create_agent_config_dir(ctx.agent_uri, tmpl)

    # The target was NOT committed (no marker / no dir) — nothing launched with the
    # revoked secret. (target may not exist at all since there was no prior dir.)
    refute File.exists?(Path.join(ctx.target, ".ezagent-config-complete"))
  end

  describe "grant-revoke rollback surfaces cleanup failure (codex H2 — FINDING 2)" do
    # On a grant-revoked-at-launch abort, the just-materialized (grant-scoped secret) dir is
    # removed; the caller gets the grant-change error.
    test "grant-revoked at launch removes the materialized config_dir", ctx do
      dir = CcAgent.agent_config_dir(ctx.agent_uri)
      write!(dir, ".credentials.json", "SECRET")
      write!(dir, ".ezagent-config-complete", "")
      assert File.exists?(dir)

      reason = {:grant_changed_before_launch, URI.to_string(ctx.agent_uri)}
      assert {:error, ^reason} = CcAgent.handle_spawn_failure(ctx.agent_uri, reason)

      # the secret dir is gone — nothing left usable for the revoked grant
      refute File.exists?(dir)
    end

    # If the cleanup rm_rf FAILS, the leftover secret dir must be surfaced as BLOCKING — the
    # caller gets a composite cleanup-failure error, NOT :ok and NOT only the grant-change.
    test "cleanup failure → composite blocking error (not :ok, not only grant-change)", ctx do
      dir = CcAgent.agent_config_dir(ctx.agent_uri)
      # Plant a read-only subdir so rm_rf of the config_dir fails.
      ro_sub = Path.join(dir, "sub")
      File.mkdir_p!(ro_sub)
      File.write!(Path.join(ro_sub, "f"), "X")
      File.write!(Path.join(dir, ".credentials.json"), "SECRET")
      File.chmod!(ro_sub, 0o500)
      on_exit(fn -> File.chmod(ro_sub, 0o700) end)

      reason = {:grant_changed_before_launch, URI.to_string(ctx.agent_uri)}
      result = CcAgent.handle_spawn_failure(ctx.agent_uri, reason)

      File.chmod!(ro_sub, 0o700)

      agent_uri = ctx.agent_uri
      assert {:error, {:grant_revoked_cleanup_failed, ^agent_uri, _cleanup_reason}} = result
      refute match?({:error, {:grant_changed_before_launch, _}}, result)
    end
  end

  describe "recover_orphaned error at materialize ENTRY (codex H)" do
    # When the crash-mid-swap self-heal (`recover_orphaned/1` at materialize entry) detects a
    # leftover known-good `.bak` + a missing/partial target but CANNOT restore it, the entry
    # MUST FAIL LOUD — proceeding to a fresh materialize could combine with a later
    # revoked-grant / missing-source failure to leave the agent with NOTHING (the `.bak` is
    # the only good copy). The recovery error must propagate, not be discarded.
    test "materialize ENTRY aborts when recover_orphaned cannot restore", ctx do
      # Own the parent so we can make it read-only without touching the shared config root.
      parent = tmp("cc-ro-parent")
      target = Path.join(parent, "cfg")

      # Crash mid-swap: target ABSENT, known-good prior tree in a sibling `.bak`.
      bak = "#{target}.bak-#{uniq()}"
      write!(bak, ".credentials.json", "PRIOR-SECRET")
      refute File.exists?(target)

      ref = tmp("cc-ref")
      write!(ref, "settings.json", "NEW")

      # Read-only parent → recover_orphaned's restore `File.rename(bak, target)` fails.
      File.chmod!(parent, 0o500)
      on_exit(fn -> File.chmod(parent, 0o700) end)

      tmpl = %{"config_dir" => ref, "allocated_config_dir" => target}

      result = CcAgent.create_agent_config_dir(ctx.agent_uri, tmpl)

      File.chmod!(parent, 0o700)

      assert {:error, {:config_dir_recover_failed, {:recover_restore_failed, ^bak, _}}} = result

      # CRITICAL: the only known-good prior tree (the `.bak`) is preserved — NOT clobbered by
      # a fresh materialize that the abort prevented.
      assert File.exists?(bak)
      assert File.read!(Path.join(bak, ".credentials.json")) == "PRIOR-SECRET"
    end
  end

  describe "grant revoked AFTER materialize, BEFORE launch (codex CRITICAL §5.1)" do
    test "create_agent_config_dir returns the materialize-time grant version", ctx do
      base = tmp("cc-base")
      write!(base, "settings.json", "BASE")
      tmpl = cascade_tmpl(ctx, [%{dir: base}])

      assert {:ok, _target, {:grant, agent_uri_str, incarnation_id, version}} =
               CcAgent.create_agent_config_dir(ctx.agent_uri, tmpl)

      assert agent_uri_str == URI.to_string(ctx.agent_uri)
      # the captured identity is the active grant's (v1 + its incarnation) — this is the
      # value the pre-launch gate re-checks.
      assert version == 1
      assert is_binary(incarnation_id)
      # the config dir IS materialized (the swap committed) — the threat is that the LATER
      # launch would proceed with this dir if the grant is revoked in between.
      assert File.exists?(Path.join(ctx.target, ".ezagent-config-complete"))
    end

    test "the pre-launch gate aborts when the grant is revoked after materialize", ctx do
      base = tmp("cc-base")
      write!(base, "settings.json", "BASE")
      tmpl = cascade_tmpl(ctx, [%{dir: base}])

      # 1. materialize commits the config_dir + captures the grant version.
      assert {:ok, _target, {:grant, agent_uri_str, incarnation_id, version}} =
               CcAgent.create_agent_config_dir(ctx.agent_uri, tmpl)

      # 2. grant revoked in the window BETWEEN materialize and the subprocess launch.
      {:ok, _} = GrantRow.revoke(agent_uri_str)

      # 3. the pre-launch re-validation (the exact GrantRow call spawn_for_local_pty's gate
      #    makes with the captured version) MUST abort the launch — no subprocess starts.
      assert {:error, :grant_changed} =
               GrantRow.revalidate_version!(agent_uri_str, incarnation_id, version)

      # 4. on that abort, spawn_for_local_pty's `else` clause clears the just-materialized
      #    config_dir via rollback_agent_config_dir/1, which removes `agent_config_dir/1`.
      #    Prove that path targets the dir we just materialized (so the revoked grant's
      #    secret is not left usable). The materialized target IS the canonical config dir.
      assert CcAgent.agent_config_dir(ctx.agent_uri) == ctx.target
      assert File.exists?(Path.join(ctx.target, ".ezagent-config-complete"))
    end
  end

  describe "cold-restart grant re-validation (§5.1)" do
    test "ensure_subprocess_alive fails loud when the agent's grant is revoked", ctx do
      {:ok, _} = GrantRow.revoke(URI.to_string(ctx.agent_uri))

      # No PtyServer alive for this fresh test URI → the revocation gate is reached
      # BEFORE any PTY rebuild → fail loud (does not respawn with stale creds).
      assert {:error, {:credential_grant_revoked, _}} =
               CcAgent.ensure_subprocess_alive(ctx.agent_uri, %{"cwd" => "/tmp"})
    end

    test "an agent with NO grant (pre-cascade) is not blocked by the gate" do
      # A fresh URI with no grant row + a bogus cwd: the gate must let it THROUGH (returns
      # false), so the failure that surfaces is the downstream PTY rebuild, NOT the gate.
      no_grant_uri = URI.new!("entity://team-a/agent/cc_nogrant-#{uniq()}")
      on_exit(fn -> File.rm_rf(CcAgent.agent_config_dir(no_grant_uri)) end)

      result = CcAgent.ensure_subprocess_alive(no_grant_uri, %{"cwd" => "/nonexistent-cwd"})
      refute match?({:error, {:credential_grant_revoked, _}}, result)
    end
  end

  describe "no whole-target overlay (codex HIGH §D4.2)" do
    test "a tombstoned file does NOT reappear from the prior target after cascade materialize",
         ctx do
      # Prior target already exists with a file that a higher layer now tombstones.
      File.mkdir_p!(Path.join(ctx.target, "plugins"))
      File.write!(Path.join(ctx.target, "plugins/old.json"), "STALE-PLUGIN")
      File.write!(Path.join(ctx.target, ".ezagent-config-complete"), "ok\n")

      base = tmp("cc-base")
      user = tmp("cc-user")
      write!(base, "plugins/old.json", "BASE-PLUGIN")
      # higher layer tombstones the inherited file
      write!(user, "plugins/old.json.tombstone", "")

      tmpl = cascade_tmpl(ctx, [%{dir: base}, %{dir: user}])

      assert {:ok, target, {:grant, _, _, _}} = CcAgent.create_agent_config_dir(ctx.agent_uri, tmpl)
      # the tombstone wins — the file must NOT be resurrected from the prior target.
      refute File.exists?(Path.join(target, "plugins/old.json"))
      refute File.exists?(Path.join(target, "plugins/old.json.tombstone"))
      # secret still copied from the source
      assert File.read!(Path.join(target, ".credentials.json")) == "ALICE-TOKEN"
    end

    test "a stale secret in the prior target does NOT survive when the source lacks it", ctx do
      # Prior target holds an OLD credential (e.g. from a now-revoked/changed source).
      File.mkdir_p!(ctx.target)
      File.write!(Path.join(ctx.target, ".credentials.json"), "OLD-STALE-TOKEN")
      File.write!(Path.join(ctx.target, ".ezagent-config-complete"), "ok\n")

      # Resolved source has NO secret (not logged in / source rotated it away).
      empty_source = tmp("cc-empty-src")

      base = tmp("cc-base")
      write!(base, "settings.json", "BASE")

      tmpl = %{
        "config_dir" => base,
        "allocated_config_dir" => ctx.target,
        "cascade" => %{
          layer_dirs: [%{dir: base}],
          source_dir_for: fn _ -> {:ok, empty_source} end
        }
      }

      assert {:ok, target, {:grant, _, _, _}} = CcAgent.create_agent_config_dir(ctx.agent_uri, tmpl)
      # the stale secret from the prior target must NOT survive — the merge tree has no
      # secret and the source supplied none, so the agent has no credential file.
      refute File.exists?(Path.join(target, ".credentials.json"))
      assert File.read!(Path.join(target, "settings.json")) == "BASE"
    end
  end

  test "crash-mid-swap leftover .bak + missing target is recovered at materialize entry",
       ctx do
    # Simulate a prior atomic_replace that died after move-aside, before rename: a
    # known-good `<target>.bak-*` exists while the target is absent.
    bak = "#{ctx.target}.bak-#{uniq()}"
    File.mkdir_p!(bak)
    File.write!(Path.join(bak, ".credentials.json"), "PRIOR-SECRET")
    File.write!(Path.join(bak, ".ezagent-config-complete"), "ok\n")
    on_exit(fn -> File.rm_rf(bak) end)
    refute File.dir?(ctx.target)

    base = tmp("cc-base")
    write!(base, "settings.json", "BASE")
    tmpl = cascade_tmpl(ctx, [%{dir: base}])

    assert {:ok, target, {:grant, _, _, _}} = CcAgent.create_agent_config_dir(ctx.agent_uri, tmpl)
    assert target == ctx.target
    # recovery consumed the orphan `.bak` (entry-point self-heal ran)
    refute File.exists?(bak)
    # a complete, fresh tree is in place
    assert File.exists?(Path.join(target, ".ezagent-config-complete"))
    assert File.read!(Path.join(target, "settings.json")) == "BASE"
  end

  test "missing mandatory control fails loud (G1)", ctx do
    base = tmp("cc-base")
    write!(base, "settings.json", "BASE")

    tmpl = %{
      "config_dir" => base,
      "allocated_config_dir" => ctx.target,
      "cascade" => %{
        layer_dirs: [%{dir: base, mandatory: ["hooks/required.sh"]}],
        source_dir_for: fn _ -> {:ok, ctx.source_dir} end
      }
    }

    assert {:error,
            {:cascade_materialize_failed, {:mandatory_control_missing, "hooks/required.sh"}}} =
             CcAgent.create_agent_config_dir(ctx.agent_uri, tmpl)
  end
end
