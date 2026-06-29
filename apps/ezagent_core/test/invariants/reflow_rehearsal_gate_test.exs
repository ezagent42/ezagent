defmodule EzagentCore.Invariants.ReflowRehearsalGateTest do
  use ExUnit.Case, async: true

  import Bitwise

  @repo_root Path.expand("../../../../", __DIR__)

  defp read!(path), do: File.read!(Path.join(@repo_root, path))
  defp exists?(path), do: File.exists?(Path.join(@repo_root, path))

  test "reflow.sh performs a full stable data reflow and does not restore target credentials" do
    script = read!("docker/reflow.sh")

    assert script =~ "FULL data reflow including credentials"
    assert script =~ "stable"
    assert script =~ "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
    assert script =~ "cp -a /src/. /dst/"

    refute script =~ "CRED_TABLES"
    refute script =~ "CRED_FS_PATH"
    refute script =~ "tgt-creds"
    refute script =~ "tgt-credfs"
    refute script =~ "session_replication_role"
    refute script =~ "prod 凭据被替换"
  end

  test "verify-rehearsal.sh is executable and implements the six post-migration gates" do
    path = Path.join(@repo_root, "docker/verify-rehearsal.sh")

    assert exists?("docker/verify-rehearsal.sh")
    assert (File.stat!(path).mode &&& 0o111) != 0

    script = File.read!(path)

    assert script =~ "Migration log clean"
    assert script =~ "Row-count sanity"
    assert script =~ "ConfigObject decode"
    assert script =~ "Schema version"
    assert script =~ "Agent slice integrity"
    assert script =~ "HTTP serve"

    for table <- [
          "users",
          "entity_profiles",
          "socialware_config_objects",
          "kind_snapshots",
          "messages",
          "sessions"
        ] do
      assert script =~ table
    end

    assert script =~ "schema_migrations"
    assert script =~ "binary_to_term"
    assert script =~ "/login"
  end

  test "deploy workflow runs backup, full reflow, and rehearsal verification after nightly and beta deploys only" do
    workflow = read!(".github/workflows/deploy.yml")

    assert workflow =~ "docker/backup.sh \"${{ steps.ch.outputs.channel }}\""
    assert workflow =~ "docker/reflow.sh \"${{ steps.ch.outputs.channel }}\""
    assert workflow =~ "docker/verify-rehearsal.sh \"${{ steps.ch.outputs.channel }}\""
    assert workflow =~ "steps.ch.outputs.channel != 'stable'"
    assert workflow =~ "steps.ch.outputs.channel == 'beta'"
    assert workflow =~ "docker/smoke.sh beta"
  end

  test "ezagent-deploy skill documents build promote reflow verify smoke and dev-together references it" do
    skill = read!(".claude/skills/ezagent-deploy/SKILL.md")
    dev_together = read!(".claude/skills/dev-together/SKILL.md")

    assert skill =~ "build"
    assert skill =~ "promote"
    assert skill =~ "reflow"
    assert skill =~ "verify"
    assert skill =~ "smoke"
    assert skill =~ "backup.sh"
    assert skill =~ "verify-rehearsal.sh"
    assert skill =~ "stable is the source"

    assert dev_together =~ "ezagent-deploy"
  end
end
