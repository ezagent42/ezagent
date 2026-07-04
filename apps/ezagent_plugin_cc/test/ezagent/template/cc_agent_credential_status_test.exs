defmodule Ezagent.PluginCc.Template.CcAgentCredentialStatusTest do
  @moduledoc """
  #160 — the cc enum adapter (§2.1): `CcAgent.credential_status/2` maps the
  cc-native `CredentialFreshness.status/2` classification onto the flavor-agnostic
  normalized enum, and populates `expires_at` (cc is the one flavor with a real
  OAuth `expiresAt`). Also asserts cc-headless delegates identically.
  """
  use ExUnit.Case, async: true

  alias Ezagent.PluginCc.Template.{CcAgent, CcHeadlessAgent}

  @now 1_700_000_000_000

  setup do
    dir = Path.join(System.tmp_dir!(), "cc-cred-status-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp write_cred(dir, oauth),
    do: File.write!(Path.join(dir, ".credentials.json"), Jason.encode!(%{"claudeAiOauth" => oauth}))

  test "fresh → :authenticated, with expires_at populated", %{dir: dir} do
    write_cred(dir, %{"accessToken" => "a", "expiresAt" => @now + 3_600_000})
    assert %{status: :authenticated, expires_at: exp} = CcAgent.credential_status(dir, now_ms: @now)
    assert exp == @now + 3_600_000
  end

  test "expired → :expired, with a re-login detail", %{dir: dir} do
    write_cred(dir, %{"accessToken" => "a", "expiresAt" => @now - 1})
    assert %{status: :expired, detail: detail} = CcAgent.credential_status(dir, now_ms: @now)
    assert detail =~ "login"
  end

  test "expiring within skew → :expiring", %{dir: dir} do
    write_cred(dir, %{"accessToken" => "a", "expiresAt" => @now + 30_000})

    assert %{status: :expiring} =
             CcAgent.credential_status(dir, now_ms: @now, skew_ms: 60_000)
  end

  test "absent file → :missing (distinct logged-out signal)", %{dir: dir} do
    assert %{status: :missing, expires_at: nil} = CcAgent.credential_status(dir, now_ms: @now)
  end

  test "garbled file → :unknown", %{dir: dir} do
    File.write!(Path.join(dir, ".credentials.json"), "{not json")
    assert %{status: :unknown} = CcAgent.credential_status(dir, now_ms: @now)
  end

  test "nil home → :unknown" do
    assert %{status: :unknown} = CcAgent.credential_status(nil)
  end

  test "cc-headless delegates to cc (same mapping)", %{dir: dir} do
    write_cred(dir, %{"accessToken" => "a", "expiresAt" => @now - 1})

    assert CcHeadlessAgent.credential_status(dir, now_ms: @now) ==
             CcAgent.credential_status(dir, now_ms: @now)
  end
end
