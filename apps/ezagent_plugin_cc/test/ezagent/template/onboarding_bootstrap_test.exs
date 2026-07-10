defmodule Ezagent.PluginCc.Template.OnboardingBootstrapTest do
  @moduledoc """
  §5.B follow-up (b) — DURABLE fix for the interactive cc agent stalling at
  claude's first-run theme / "Select login method" dialogs despite a valid
  materialized `.credentials.json`.

  The reliable fix (verified in `project_headless_claude_startup_dialogs`): mark
  claude's OWN onboarding as complete in the per-agent `CLAUDE_CONFIG_DIR/.claude.json`
  so claude never enters the first-run flow (theme picker → login-method picker).
  A materialized credential alone does NOT suppress that flow.

  `OnboardingBootstrap.ensure/1` writes `hasCompletedOnboarding: true` (+ a default
  `theme`) into `<config_dir>/.claude.json`, MERGING with any existing file and
  NEVER clobbering an existing `theme` or other keys (idempotent, non-destructive).
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias Ezagent.PluginCc.Template.OnboardingBootstrap

  setup do
    dir = Path.join(System.tmp_dir!(), "cc-onboard-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp read_claude_json(dir) do
    dir |> Path.join(".claude.json") |> File.read!() |> Jason.decode!()
  end

  test "nil config_dir is a no-op", _ctx do
    assert OnboardingBootstrap.ensure(nil) == :ok
  end

  test "creates .claude.json with onboarding-completion marker when absent", %{dir: dir} do
    refute File.exists?(Path.join(dir, ".claude.json"))

    assert OnboardingBootstrap.ensure(dir) == :ok

    json = read_claude_json(dir)
    assert json["hasCompletedOnboarding"] == true

    # A default theme is set so the theme picker never appears either.
    assert is_binary(json["theme"]) and json["theme"] != ""
  end

  test "merges into an existing .claude.json without clobbering unrelated keys", %{dir: dir} do
    existing = %{"theme" => "light", "projects" => %{"/some/cwd" => %{"allowedTools" => []}}}
    File.write!(Path.join(dir, ".claude.json"), Jason.encode!(existing))

    assert OnboardingBootstrap.ensure(dir) == :ok

    json = read_claude_json(dir)
    assert json["hasCompletedOnboarding"] == true
    # MUST NOT overwrite an existing theme the operator/agent already chose.
    assert json["theme"] == "light"
    # MUST preserve unrelated keys.
    assert json["projects"]["/some/cwd"]["allowedTools"] == []
  end

  test "is idempotent — re-running does not error or change the marker", %{dir: dir} do
    assert OnboardingBootstrap.ensure(dir) == :ok
    first = read_claude_json(dir)
    assert OnboardingBootstrap.ensure(dir) == :ok
    second = read_claude_json(dir)
    assert first == second
    assert second["hasCompletedOnboarding"] == true
  end

  test "surfaces a clear error when the existing .claude.json is corrupt", %{dir: dir} do
    File.write!(Path.join(dir, ".claude.json"), "{ this is not json")
    assert {:error, {:claude_json_undecodable, _}} = OnboardingBootstrap.ensure(dir)
  end

  test "the written file is private (0600)", %{dir: dir} do
    assert OnboardingBootstrap.ensure(dir) == :ok
    {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(dir, ".claude.json"))
    # low 9 bits = 0o600
    assert band(mode, 0o777) == 0o600
  end

  # #505 — pre-set the PROJECT-scoped trust gates so a headless cc PTY never
  # stalls at claude 2.x's per-project startup dialogs (trust folder / external
  # CLAUDE.md imports / new MCP server). Keyed by the agent's cwd.
  test "project_cwd pre-sets the project-scoped trust + import + mcp approval keys", %{dir: dir} do
    cwd = "/private/tmp/some-agent-cwd"
    assert OnboardingBootstrap.ensure(dir, project_cwd: cwd) == :ok

    json = read_claude_json(dir)
    project = json["projects"][Path.expand(cwd)]

    assert project["hasTrustDialogAccepted"] == true
    assert project["hasClaudeMdExternalIncludesApproved"] == true
    assert project["hasCompletedProjectOnboarding"] == true
    assert project["enableAllProjectMcpServers"] == true
    # top-level onboarding marker still set.
    assert json["hasCompletedOnboarding"] == true
  end

  test "project_cwd merges into an existing project entry without clobbering it", %{dir: dir} do
    cwd = "/private/tmp/agent-cwd2"

    existing = %{"projects" => %{Path.expand(cwd) => %{"allowedTools" => ["Bash"]}}}
    File.write!(Path.join(dir, ".claude.json"), Jason.encode!(existing))

    assert OnboardingBootstrap.ensure(dir, project_cwd: cwd) == :ok

    project = read_claude_json(dir)["projects"][Path.expand(cwd)]
    assert project["allowedTools"] == ["Bash"]
    assert project["hasClaudeMdExternalIncludesApproved"] == true
  end

  test "a non-object projects key does not crash the best-effort path", %{dir: dir} do
    # Hand-edited / corrupt .claude.json with a non-object "projects" must not
    # raise out of the best-effort spawn path (codex review).
    File.write!(Path.join(dir, ".claude.json"), Jason.encode!(%{"projects" => "oops"}))

    assert OnboardingBootstrap.ensure(dir, project_cwd: "/private/tmp/x") == :ok
    json = read_claude_json(dir)
    assert json["projects"][Path.expand("/private/tmp/x")]["hasClaudeMdExternalIncludesApproved"] ==
             true
  end

  test "try_ensure rescues an unexpected error and returns :ok (scanner is the fallback)", %{
    dir: dir
  } do
    uri = Ezagent.URI.new!("entity://system/agent/onb-#{System.unique_integer([:positive])}")
    # A corrupt existing file makes ensure/2 return {:error, _}; try_ensure swallows it.
    File.write!(Path.join(dir, ".claude.json"), "{ not json")
    assert OnboardingBootstrap.try_ensure(dir, uri, project_cwd: "/tmp/y") == :ok
  end

  test "no project_cwd leaves projects untouched (backward compatible)", %{dir: dir} do
    existing = %{"projects" => %{"/some/cwd" => %{"allowedTools" => []}}}
    File.write!(Path.join(dir, ".claude.json"), Jason.encode!(existing))

    assert OnboardingBootstrap.ensure(dir) == :ok

    json = read_claude_json(dir)
    assert json["projects"] == %{"/some/cwd" => %{"allowedTools" => []}}
  end

  # Channel-inject entitlement — materialize the `tengu_harbor` GrowthBook feature
  # so the `claude/channel` inject capability registers on a non-Anthropic backend
  # (deepseek/GLM), letting server-pushed `@mentions` reach the agent. Cache-only,
  # no Anthropic OAuth. See the module's §"Two concerns".
  test "materializes cachedGrowthBookFeatures with tengu_harbor + a timestamp", %{dir: dir} do
    assert OnboardingBootstrap.ensure(dir) == :ok

    json = read_claude_json(dir)
    assert json["cachedGrowthBookFeatures"]["tengu_harbor"] == true
    # A fresh ms timestamp so claude treats the cache as usable.
    assert is_integer(json["cachedGrowthBookFeaturesAt"])
    assert json["cachedGrowthBookFeaturesAt"] > 0
  end

  test "merges tengu_harbor INTO an existing feature blob without clobbering siblings", %{dir: dir} do
    # Simulates creds copied from an Anthropic-backed home carrying the full blob.
    existing = %{
      "cachedGrowthBookFeatures" => %{"tengu_other_flag" => "on", "tengu_harbor" => false},
      "cachedGrowthBookFeaturesAt" => 111
    }

    File.write!(Path.join(dir, ".claude.json"), Jason.encode!(existing))

    assert OnboardingBootstrap.ensure(dir) == :ok

    json = read_claude_json(dir)
    # tengu_harbor is force-set true even if it was previously false/absent.
    assert json["cachedGrowthBookFeatures"]["tengu_harbor"] == true
    # sibling features preserved.
    assert json["cachedGrowthBookFeatures"]["tengu_other_flag"] == "on"
    # an existing timestamp is preserved (set-if-absent → proven-safe even stale).
    assert json["cachedGrowthBookFeaturesAt"] == 111
  end

  test "channel-feature injection is idempotent (stable timestamp across runs)", %{dir: dir} do
    assert OnboardingBootstrap.ensure(dir) == :ok
    first = read_claude_json(dir)
    assert OnboardingBootstrap.ensure(dir) == :ok
    second = read_claude_json(dir)

    assert first["cachedGrowthBookFeatures"] == second["cachedGrowthBookFeatures"]
    assert first["cachedGrowthBookFeaturesAt"] == second["cachedGrowthBookFeaturesAt"]
  end

  test "a non-object cachedGrowthBookFeatures is replaced, not crashed", %{dir: dir} do
    # Hand-edited / corrupt file with a non-object features key must not raise.
    File.write!(
      Path.join(dir, ".claude.json"),
      Jason.encode!(%{"cachedGrowthBookFeatures" => "oops"})
    )

    assert OnboardingBootstrap.ensure(dir) == :ok
    json = read_claude_json(dir)
    assert json["cachedGrowthBookFeatures"]["tengu_harbor"] == true
  end
end
