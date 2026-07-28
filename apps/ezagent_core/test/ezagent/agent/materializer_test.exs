defmodule Ezagent.Agent.MaterializerTest do
  @moduledoc """
  #17 cascade PR-2 invariant tests for the flavor-generic materializer (spec §7, §D4.1,
  §D4.2, §D6, §5.1). The atomic-replace failure-injection tests (§7 / H3') are the most
  important: a failed materialization MUST leave the PRIOR good config_dir intact.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.Materializer
  alias Ezagent.Credential.GrantRow

  setup do
    base = Path.join(System.tmp_dir!(), "matz-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  defp write!(dir, rel, contents) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp read(dir, rel), do: File.read(Path.join(dir, rel))

  # ── atomic-replace-with-rollback (§7 / H3') ────────────────────────────────

  describe "atomic_replace/3 — happy path" do
    test "replaces target with staging and drops the .bak", %{base: base} do
      target = Path.join(base, "target")
      staging = Path.join(base, "staging")
      write!(target, "old.txt", "OLD")
      write!(staging, "new.txt", "NEW")

      assert {:ok, ^target} = Materializer.atomic_replace(staging, target)

      assert {:ok, "NEW"} = read(target, "new.txt")
      assert {:error, _} = read(target, "old.txt")
      refute File.exists?(staging)
      # no .bak left behind
      assert base |> File.ls!() |> Enum.reject(&(&1 == "target")) == []
    end

    test "creates target fresh when there was no prior target", %{base: base} do
      target = Path.join(base, "fresh")
      staging = Path.join(base, "staging")
      write!(staging, "a.txt", "A")
      refute File.exists?(target)

      assert {:ok, ^target} = Materializer.atomic_replace(staging, target)
      assert {:ok, "A"} = read(target, "a.txt")
    end
  end

  describe "atomic_replace/3 — FAILURE INJECTION (§7 H3' — the critical test)" do
    test "crash after move-aside restores the PRIOR good config_dir intact", %{base: base} do
      target = Path.join(base, "target")
      staging = Path.join(base, "staging")
      # Prior good config_dir: a credential + a config file.
      write!(target, ".credentials.json", "SECRET-TOKEN")
      write!(target, "settings.json", "{\"good\":true}")
      write!(staging, "settings.json", "{\"new\":true}")

      assert {:error, {:atomic_replace_failed, :injected_failure_after_move}} =
               Materializer.atomic_replace(staging, target, fail_after_move: true)

      # PRIOR tree fully restored — never empty, never half-merged.
      assert File.dir?(target)
      assert {:ok, "SECRET-TOKEN"} = read(target, ".credentials.json")
      assert {:ok, "{\"good\":true}"} = read(target, "settings.json")
      # staging cleaned up; no orphan .bak
      refute File.exists?(staging)
      assert base |> File.ls!() |> Enum.reject(&(&1 == "target")) == []
    end

    test "rename failure (staging missing) restores the prior target", %{base: base} do
      target = Path.join(base, "target")
      staging = Path.join(base, "does-not-exist")
      write!(target, "keep.txt", "KEEP")

      assert {:error, {:atomic_replace_failed, _}} =
               Materializer.atomic_replace(staging, target)

      assert File.dir?(target)
      assert {:ok, "KEEP"} = read(target, "keep.txt")
    end

    test "injected failure with NO prior target leaves no half dir", %{base: base} do
      target = Path.join(base, "target")
      staging = Path.join(base, "staging")
      write!(staging, "a.txt", "A")
      refute File.exists?(target)

      assert {:error, _} = Materializer.atomic_replace(staging, target, fail_after_move: true)
      refute File.exists?(target)
    end

    # codex H3' (a) — a FAILED rollback must SURFACE, not be swallowed as success. We
    # simulate a half-completed rename: the injection hook plants a PARTIAL `target` with a
    # read-only subdir BEFORE the rollback runs, so the rollback's `rm_rf(target)` cannot
    # clear it and therefore cannot put the prior tree back → the error must say so.
    test "restore failure SURFACES a rollback-failed error (not silent :ok)", %{base: base} do
      target = Path.join(base, "target")
      staging = Path.join(base, "staging")
      write!(target, ".credentials.json", "PRIOR-SECRET")
      write!(staging, "settings.json", "NEW")

      plant_unclearable_partial = fn ->
        # After move-aside, `target` is gone (it's in `.bak`). Plant a partial new target
        # with a read-only subdir so the rollback's `rm_rf(target)` fails with :eexist.
        ro_sub = Path.join([target, "sub"])
        File.mkdir_p!(ro_sub)
        File.write!(Path.join(ro_sub, "f.txt"), "X")
        File.chmod!(ro_sub, 0o500)
      end

      result =
        Materializer.atomic_replace(staging, target,
          fail_after_move: true,
          on_fail_after_move: plant_unclearable_partial
        )

      assert {:error, {:atomic_replace_rollback_failed, original: _, rollback: _}} = result

      # restore perms so on_exit cleanup can remove the tree, and confirm the `.bak`
      # (known-good prior tree) is STILL on disk for `recover_orphaned/1` to retry.
      File.chmod!(Path.join([target, "sub"]), 0o700)

      baks =
        base |> File.ls!() |> Enum.filter(&String.contains?(&1, ".bak-"))

      assert baks != []
      assert {:ok, "PRIOR-SECRET"} = read(Path.join(base, List.first(baks)), ".credentials.json")
    end
  end

  describe "recover_orphaned/1 — crash-mid-swap self-heal (§7 H3' (b))" do
    test "restores a leftover .bak when the target is missing", %{base: base} do
      target = Path.join(base, "cfg")
      # Simulate a crash AFTER move-aside, BEFORE rename: prior tree sits in a `.bak`, the
      # target is absent.
      bak = "#{target}.bak-#{System.unique_integer([:positive])}"
      write!(bak, ".credentials.json", "PRIOR-SECRET")
      write!(bak, "settings.json", "PRIOR-CFG")
      refute File.exists?(target)

      assert {:recovered, ^target} = Materializer.recover_orphaned(target)

      # the known-good prior tree is back in place
      assert {:ok, "PRIOR-SECRET"} = read(target, ".credentials.json")
      assert {:ok, "PRIOR-CFG"} = read(target, "settings.json")
      # the orphan `.bak` is consumed
      refute File.exists?(bak)
    end

    test "drops a stale .bak when the target is already present + usable", %{base: base} do
      target = Path.join(base, "cfg")
      write!(target, "settings.json", "COMMITTED")
      write!(target, ".ezagent-config-complete", "ok\n")
      bak = "#{target}.bak-#{System.unique_integer([:positive])}"
      write!(bak, "settings.json", "STALE")

      assert :ok = Materializer.recover_orphaned(target)
      # the committed target is untouched; the stale `.bak` is dropped
      assert {:ok, "COMMITTED"} = read(target, "settings.json")
      refute File.exists?(bak)
    end

    test "is a no-op when there is no .bak", %{base: base} do
      target = Path.join(base, "cfg")
      write!(target, "settings.json", "OK")
      assert :ok = Materializer.recover_orphaned(target)
      assert {:ok, "OK"} = read(target, "settings.json")
    end

    # codex H (recover_orphaned restore-failure) — when the restore (`File.rename`) FAILS,
    # the selected `.bak` is the ONLY known-good copy of the prior config. The recovery MUST
    # NOT drop it (a dropped `.bak` + a missing/partial target = agent left with NOTHING).
    test "restore FAILURE preserves the .bak and returns an error", %{base: base} do
      # Crash mid-swap: target ABSENT (not usable), the known-good prior tree in a sibling
      # `.bak`. Make the shared PARENT dir read-only so the restore `File.rename(bak, target)`
      # FAILS (eacces) — exercising the restore-failure path.
      parent = Path.join(base, "ro-parent")
      File.mkdir_p!(parent)
      target = Path.join(parent, "cfg")
      bak = "#{target}.bak-#{System.unique_integer([:positive])}"
      write!(bak, ".credentials.json", "PRIOR-SECRET")
      refute File.exists?(target)

      File.chmod!(parent, 0o500)

      result = Materializer.recover_orphaned(target)

      # restore perms so on_exit cleanup can remove the tree
      File.chmod!(parent, 0o700)

      assert {:error, {:recover_restore_failed, ^bak, _reason}} = result

      # CRITICAL: the only known-good prior tree (the `.bak`) MUST still be on disk — the
      # recovery must NOT drop the very backup it failed to restore.
      assert File.exists?(bak)
      assert {:ok, "PRIOR-SECRET"} = read(bak, ".credentials.json")
    end

    test "markerless non-empty target is partial and restores the .bak", %{base: base} do
      target = Path.join(base, "cfg")
      write!(target, "partial.txt", "PARTIAL")
      refute File.exists?(Path.join(target, ".ezagent-config-complete"))

      bak = "#{target}.bak-#{System.unique_integer([:positive])}"
      write!(bak, ".credentials.json", "PRIOR-SECRET")
      write!(bak, "settings.json", "PRIOR-CFG")
      write!(bak, ".ezagent-config-complete", "ok\n")

      assert {:recovered, ^target} = Materializer.recover_orphaned(target)

      assert {:ok, "PRIOR-SECRET"} = read(target, ".credentials.json")
      assert {:ok, "PRIOR-CFG"} = read(target, "settings.json")
      assert {:ok, "ok\n"} = read(target, ".ezagent-config-complete")
      assert {:error, _} = read(target, "partial.txt")
      refute File.exists?(bak)
    end
  end

  # ── layer merge: whole-file-replace + directory-union (§D4.1 / §D4.2) ───────

  describe "merge_layers/2 — precedence" do
    test "higher layer wins on same-path config file (whole-file-replace)", %{base: base} do
      ws = Path.join(base, "ws")
      user = Path.join(base, "user")
      staging = Path.join(base, "staging")
      write!(ws, "settings.json", "WS")
      write!(user, "settings.json", "USER")

      assert :ok = Materializer.merge_layers(staging, [%{dir: ws}, %{dir: user}])
      # user (higher) wins
      assert {:ok, "USER"} = read(staging, "settings.json")
    end

    test "directory-union: files unique to each layer all appear", %{base: base} do
      base_l = Path.join(base, "base")
      ws = Path.join(base, "ws")
      staging = Path.join(base, "staging")
      write!(base_l, "plugins/a.json", "A")
      write!(ws, "plugins/b.json", "B")

      assert :ok = Materializer.merge_layers(staging, [%{dir: base_l}, %{dir: ws}])
      assert {:ok, "A"} = read(staging, "plugins/a.json")
      assert {:ok, "B"} = read(staging, "plugins/b.json")
    end

    test "fails loud when a layer dir is declared but missing", %{base: base} do
      staging = Path.join(base, "staging")

      assert {:error, {:layer_dir_missing, _}} =
               Materializer.merge_layers(staging, [%{dir: Path.join(base, "nope")}])
    end
  end

  describe "merge_layers/2 — tombstone trust (§D4.2 H2')" do
    test "a non-protected inherited file CAN be tombstoned freely", %{base: base} do
      base_l = Path.join(base, "base")
      user = Path.join(base, "user")
      staging = Path.join(base, "staging")
      write!(base_l, "plugins/optional.json", "OPT")
      write!(user, "plugins/optional.json.tombstone", "")

      assert :ok = Materializer.merge_layers(staging, [%{dir: base_l}, %{dir: user}])
      # removed from merged tree; marker stripped
      assert {:error, _} = read(staging, "plugins/optional.json")
      assert {:error, _} = read(staging, "plugins/optional.json.tombstone")
    end

    test "a user layer CANNOT tombstone a base/workspace PROTECTED path without mgmt cap",
         %{base: base} do
      base_l = Path.join(base, "base")
      user = Path.join(base, "user")
      staging = Path.join(base, "staging")
      write!(base_l, "hooks/policy.sh", "PROTECTED")
      write!(user, "hooks/policy.sh.tombstone", "")

      assert {:error, {:protected_tombstone_denied, "hooks/policy.sh"}} =
               Materializer.merge_layers(staging, [
                 %{dir: base_l, protected: ["hooks/policy.sh"]},
                 %{dir: user}
               ])
    end

    test "a user layer CANNOT tombstone an ancestor of a protected path without mgmt cap",
         %{base: base} do
      base_l = Path.join(base, "base")
      user = Path.join(base, "user")
      staging = Path.join(base, "staging")
      write!(base_l, "hooks/policy.sh", "PROTECTED")
      write!(user, "hooks.tombstone", "")

      assert {:error, {:protected_tombstone_denied, "hooks"}} =
               Materializer.merge_layers(staging, [
                 %{dir: base_l, protected: ["hooks/policy.sh"]},
                 %{dir: user}
               ])
    end

    test "a tombstone marker does not delete a later higher-layer replacement", %{base: base} do
      base_l = Path.join(base, "base")
      user = Path.join(base, "user")
      session = Path.join(base, "session")
      staging = Path.join(base, "staging")
      write!(base_l, "plugins/a.json", "BASE")
      write!(user, "plugins/a.json.tombstone", "")
      write!(session, "plugins/a.json", "SESSION")

      assert :ok =
               Materializer.merge_layers(staging, [
                 %{dir: base_l},
                 %{dir: user},
                 %{dir: session}
               ])

      assert {:ok, "SESSION"} = read(staging, "plugins/a.json")
      assert {:error, _} = read(staging, "plugins/a.json.tombstone")
    end

    test "a layer WITH the mgmt cap CAN tombstone a protected path", %{base: base} do
      base_l = Path.join(base, "base")
      admin = Path.join(base, "admin")
      staging = Path.join(base, "staging")
      write!(base_l, "hooks/policy.sh", "PROTECTED")
      write!(admin, "hooks/policy.sh.tombstone", "")

      assert :ok =
               Materializer.merge_layers(staging, [
                 %{dir: base_l, protected: ["hooks/policy.sh"]},
                 %{dir: admin, mgmt_cap?: true}
               ])

      assert {:error, _} = read(staging, "hooks/policy.sh")
    end
  end

  describe "merge_layers/2 — mandatory post-merge validation (§D4.1 G1)" do
    test "passes when the mandatory control survives the merge", %{base: base} do
      base_l = Path.join(base, "base")
      staging = Path.join(base, "staging")
      write!(base_l, "hooks/required.sh", "REQ")

      assert :ok =
               Materializer.merge_layers(staging, [
                 %{dir: base_l, mandatory: ["hooks/required.sh"]}
               ])
    end

    test "fails loud when a higher layer replaces-to-omit a mandatory control", %{base: base} do
      # G1: a higher layer ships a settings file that OMITS a mandatory hook. Here we
      # model the mandatory control as a discrete relpath that the higher layer's union
      # does not include and which it (incorrectly) tombstones-equivalent by overwriting
      # the dir tree such that the mandatory file is gone. We simulate the "gone" outcome
      # by NOT shipping it in any present layer while declaring it mandatory.
      ws = Path.join(base, "ws")
      staging = Path.join(base, "staging")
      write!(ws, "settings.json", "WS")

      assert {:error, {:mandatory_control_missing, "hooks/required.sh"}} =
               Materializer.merge_layers(staging, [
                 %{dir: ws, mandatory: ["hooks/required.sh"]}
               ])
    end
  end

  # ── secret-only copy (§D6) ─────────────────────────────────────────────────

  describe "copy_secret_relpaths/3 (§D6)" do
    test "copies ONLY the declared secret files, not config or other files", %{base: base} do
      source = Path.join(base, "source")
      staging = Path.join(base, "staging")
      File.mkdir_p!(staging)
      write!(source, ".credentials.json", "TOKEN")
      write!(source, "settings.json", "SOURCE-CONFIG")
      write!(source, "random.txt", "JUNK")

      assert :ok = Materializer.copy_secret_relpaths(source, staging, [".credentials.json"])
      assert {:ok, "TOKEN"} = read(staging, ".credentials.json")
      # config + junk were NOT pulled from the source
      assert {:error, _} = read(staging, "settings.json")
      assert {:error, _} = read(staging, "random.txt")
    end

    test "copied secret is chmod 0600", %{base: base} do
      source = Path.join(base, "source")
      staging = Path.join(base, "staging")
      File.mkdir_p!(staging)
      write!(source, "auth.json", "TOK")

      assert :ok = Materializer.copy_secret_relpaths(source, staging, ["auth.json"])
      %File.Stat{mode: mode} = File.stat!(Path.join(staging, "auth.json"))
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "a missing secret at the source is tolerated (not logged in yet)", %{base: base} do
      source = Path.join(base, "source")
      staging = Path.join(base, "staging")
      File.mkdir_p!(source)
      File.mkdir_p!(staging)

      assert :ok = Materializer.copy_secret_relpaths(source, staging, [".credentials.json"])
      assert {:error, _} = read(staging, ".credentials.json")
    end
  end

  # ── grant TOCTOU (§5.1 H1') ────────────────────────────────────────────────

  describe "materialize_with_grant/2 (§5.1 TOCTOU)" do
    setup %{base: base} do
      source_uri = "entity://team-a/agent/alice-base"
      {:ok, _} = Ezagent.SnapshotStore.write(source_uri, %{}, kind_type: :agent)

      source_dir = Path.join(base, "source")
      File.mkdir_p!(source_dir)
      File.write!(Path.join(source_dir, ".credentials.json"), "TOKEN")

      staging = Path.join(base, "staging")
      File.mkdir_p!(staging)

      agent_uri = "entity://team-a/agent/worker-#{System.unique_integer([:positive])}"

      {:ok, _g} =
        GrantRow.insert(%{
          agent_uri: agent_uri,
          credential_source_uri: source_uri,
          approved_by: "entity://team-a/user/alice",
          approved_scope: source_uri,
          version: 1
        })

      {:ok,
       agent_uri: agent_uri, source_uri: source_uri, source_dir: source_dir, staging: staging}
    end

    test "copies the secret and commits when the grant is stable", ctx do
      committed = :counters.new(1, [])

      result =
        Materializer.materialize_with_grant(%{
          agent_uri: ctx.agent_uri,
          staging: ctx.staging,
          secret_relpaths: [".credentials.json"],
          source_dir_for: fn _uri -> {:ok, ctx.source_dir} end,
          commit: fn {version, incarnation_id} ->
            :counters.add(committed, 1, 1)
            {:ok, {:launched, version, incarnation_id}}
          end
        })

      # commit receives the validated grant identity (version + incarnation,
      # threaded to the later launch re-check)
      assert {:ok, {:launched, 1, incarnation}} = result
      assert is_binary(incarnation)
      assert :counters.get(committed, 1) == 1
      assert {:ok, "TOKEN"} = File.read(Path.join(ctx.staging, ".credentials.json"))
    end

    test "revoke AFTER the pre-copy revalidation but BEFORE exec aborts the start", ctx do
      committed = :counters.new(1, [])

      result =
        Materializer.materialize_with_grant(%{
          agent_uri: ctx.agent_uri,
          staging: ctx.staging,
          secret_relpaths: [".credentials.json"],
          # Revoke the grant DURING source resolution — i.e. after fetch_for_materialize
          # read version 1, before the revalidate. The revalidate then sees version 2.
          source_dir_for: fn _uri ->
            {:ok, _} = GrantRow.revoke(ctx.agent_uri)
            {:ok, ctx.source_dir}
          end,
          commit: fn _version ->
            :counters.add(committed, 1, 1)
            {:ok, :launched}
          end
        })

      assert {:error, :grant_changed} = result
      # commit/exec was NEVER reached — no process launched with the revoked secret.
      assert :counters.get(committed, 1) == 0
    end

    test "a revoked grant fails before any copy", ctx do
      {:ok, _} = GrantRow.revoke(ctx.agent_uri)

      result =
        Materializer.materialize_with_grant(%{
          agent_uri: ctx.agent_uri,
          staging: ctx.staging,
          secret_relpaths: [".credentials.json"],
          source_dir_for: fn _ -> flunk("should not resolve source for a revoked grant") end,
          commit: fn _version -> flunk("should not commit for a revoked grant") end
        })

      assert {:error, :revoked} = result
    end
  end
end
