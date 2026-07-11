defmodule Ezagent.PluginCc.Template.OnboardingBootstrapApiKeyTest do
  @moduledoc """
  Concern 3 — custom-API-key confirm PRE-APPROVAL (belt-and-suspenders, PR #1333).

  claude's first-run flow shows a `Detected a custom API key in your environment /
  Do you want to use this API key?` CONFIRM dialog whenever it picks up an
  `ANTHROPIC_API_KEY` env var not yet on its `customApiKeyResponses.approved`
  allowlist. A headless PTY cannot answer it → the spawn hangs. This dialog is in
  NEITHER the deterministic pre-seed (before this fix) NOR the PtyServer
  auto-prompt scanner, so it would hang uncaught.

  Our deepseek/proxy agents use `ANTHROPIC_AUTH_TOKEN` (a SEPARATE claude branch
  that never enters this confirm), so in normal operation the dialog cannot fire.
  `merge_api_key_approvals/1` guards the failure mode where a deploy erroneously
  sets `ANTHROPIC_API_KEY`: it pre-seeds the key's LAST-20-CHARS approval id
  (claude 2.1.206 `D4(e) = e.slice(-20)`), so the confirm never appears.

  `async: false` — these tests mutate the process env var `ANTHROPIC_API_KEY`,
  which the module reads via `System.get_env/1`.
  """

  use ExUnit.Case, async: false

  alias Ezagent.PluginCc.Template.OnboardingBootstrap

  @env "ANTHROPIC_API_KEY"

  setup do
    prior = System.get_env(@env)
    System.delete_env(@env)

    on_exit(fn ->
      case prior do
        nil -> System.delete_env(@env)
        val -> System.put_env(@env, val)
      end
    end)

    dir = Path.join(System.tmp_dir!(), "cc-onboard-apikey-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp read_claude_json(dir) do
    dir |> Path.join(".claude.json") |> File.read!() |> Jason.decode!()
  end

  test "pre-approves an env ANTHROPIC_API_KEY by its last-20-chars (claude D4=slice(-20))",
       %{dir: dir} do
    key = "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    System.put_env(@env, key)

    assert OnboardingBootstrap.ensure(dir) == :ok

    approved = read_claude_json(dir)["customApiKeyResponses"]["approved"]
    # last 20 chars = the exact identifier claude's `approved?.includes(D4(t))` gate checks.
    assert approved == [String.slice(key, -20, 20)]
    assert String.length(hd(approved)) == 20
  end

  test "no-op when ANTHROPIC_API_KEY is unset — the normal AUTH_TOKEN case", %{dir: dir} do
    # (setup already deleted the env var)
    assert OnboardingBootstrap.ensure(dir) == :ok
    # The confirm can't fire without ANTHROPIC_API_KEY, so we write nothing for it.
    refute Map.has_key?(read_claude_json(dir), "customApiKeyResponses")
  end

  test "a key of 20 chars or fewer is stored whole (slice(-20) parity)", %{dir: dir} do
    key = "short-key-123"
    System.put_env(@env, key)

    assert OnboardingBootstrap.ensure(dir) == :ok

    approved = read_claude_json(dir)["customApiKeyResponses"]["approved"]
    assert approved == [key]
  end

  test "idempotent — re-running does not duplicate the approval id", %{dir: dir} do
    System.put_env(@env, "sk-ant-DUPLICATE-CHECK-0000000000")

    assert OnboardingBootstrap.ensure(dir) == :ok
    assert OnboardingBootstrap.ensure(dir) == :ok

    approved = read_claude_json(dir)["customApiKeyResponses"]["approved"]
    assert length(approved) == 1
  end

  test "merges into an existing customApiKeyResponses without clobbering approved/rejected",
       %{dir: dir} do
    existing = %{
      "customApiKeyResponses" => %{
        "approved" => ["operator-preapproved-000"],
        "rejected" => ["some-rejected-key-9999"]
      }
    }

    File.write!(Path.join(dir, ".claude.json"), Jason.encode!(existing))

    key = "sk-ant-NEWKEY-1234567890ABCDEFGH"
    System.put_env(@env, key)

    assert OnboardingBootstrap.ensure(dir) == :ok

    responses = read_claude_json(dir)["customApiKeyResponses"]
    # pre-existing operator approval preserved, new id appended.
    assert "operator-preapproved-000" in responses["approved"]
    assert String.slice(key, -20, 20) in responses["approved"]
    # a pre-existing rejected list is never dropped.
    assert responses["rejected"] == ["some-rejected-key-9999"]
  end

  test "a non-object customApiKeyResponses is replaced, not crashed", %{dir: dir} do
    File.write!(
      Path.join(dir, ".claude.json"),
      Jason.encode!(%{"customApiKeyResponses" => "oops"})
    )

    System.put_env(@env, "sk-ant-CORRUPT-RECOVER-000000000")

    assert OnboardingBootstrap.ensure(dir) == :ok
    approved = read_claude_json(dir)["customApiKeyResponses"]["approved"]
    assert approved == [String.slice("sk-ant-CORRUPT-RECOVER-000000000", -20, 20)]
  end
end
