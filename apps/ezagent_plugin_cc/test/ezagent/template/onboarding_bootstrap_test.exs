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
end
