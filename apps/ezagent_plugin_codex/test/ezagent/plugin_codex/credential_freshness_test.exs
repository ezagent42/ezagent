defmodule EzagentPluginCodex.CredentialFreshnessTest do
  @moduledoc """
  #160 — the NEW read-only codex credential probe. present/absent/unreadable only
  (codex `auth.json` has no readable `expiresAt`; the CLI self-refreshes). No
  network I/O, no `last_refresh` heuristic.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginCodex.CredentialFreshness

  setup do
    home = Path.join(System.tmp_dir!(), "codex-cred-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf(home) end)
    {:ok, home: home}
  end

  defp write_auth(home, map),
    do: File.write!(Path.join(home, "auth.json"), Jason.encode!(map))

  test "absent auth.json → :missing (logged out / never codex login)", %{home: home} do
    assert CredentialFreshness.status(home) == :missing
  end

  test "present auth.json with tokens → :authenticated", %{home: home} do
    write_auth(home, %{
      "tokens" => %{"access_token" => "a", "refresh_token" => "r"},
      "last_refresh" => "2026-07-01T00:00:00Z"
    })

    assert CredentialFreshness.status(home) == :authenticated
  end

  test "present but garbled auth.json → :unknown", %{home: home} do
    File.write!(Path.join(home, "auth.json"), "{not json")
    assert CredentialFreshness.status(home) == :unknown
  end

  test "present empty JSON object → :unknown (no credential material)", %{home: home} do
    write_auth(home, %{})
    assert CredentialFreshness.status(home) == :unknown
  end

  test "an old last_refresh is STILL :authenticated (no staleness heuristic in v1)", %{home: home} do
    write_auth(home, %{
      "tokens" => %{"access_token" => "a", "refresh_token" => "r"},
      # ~100 days ago — codex self-refreshes; we do NOT guess it's dead.
      "last_refresh" => "2026-03-20T00:00:00Z"
    })

    assert CredentialFreshness.status(home) == :authenticated
  end

  test "nil home → :unknown" do
    assert CredentialFreshness.status(nil) == :unknown
  end
end
