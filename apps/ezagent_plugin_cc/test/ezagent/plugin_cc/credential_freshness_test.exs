defmodule EzagentPluginCc.CredentialFreshnessTest do
  use ExUnit.Case, async: true

  alias EzagentPluginCc.CredentialFreshness

  @now 1_700_000_000_000

  setup do
    dir = Path.join(System.tmp_dir!(), "cc-cred-fresh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp write_cred(dir, oauth) when is_map(oauth) do
    File.write!(Path.join(dir, ".credentials.json"), Jason.encode!(%{"claudeAiOauth" => oauth}))
  end

  defp write_raw(dir, json), do: File.write!(Path.join(dir, ".credentials.json"), json)

  describe "check/2" do
    test "a token expiring far in the future is :fresh", %{dir: dir} do
      write_cred(dir, %{"accessToken" => "a", "expiresAt" => @now + 3_600_000})
      assert CredentialFreshness.check(dir, now_ms: @now) == :fresh
    end

    test "a token whose expiresAt is at/before now is {:stale, :expired}", %{dir: dir} do
      write_cred(dir, %{"accessToken" => "a", "expiresAt" => @now - 1})
      assert CredentialFreshness.check(dir, now_ms: @now) == {:stale, :expired}
    end

    test "a token expiring within the skew window is {:stale, :expiring_soon}", %{dir: dir} do
      write_cred(dir, %{"accessToken" => "a", "expiresAt" => @now + 30_000})

      assert CredentialFreshness.check(dir, now_ms: @now, skew_ms: 60_000) ==
               {:stale, :expiring_soon}
    end

    test "a missing .credentials.json is :unknown (could be api_key_helper / pre-login)", %{
      dir: dir
    } do
      assert CredentialFreshness.check(dir, now_ms: @now) == :unknown
    end

    test "a present but non-OAuth-shaped cred is :unknown (e.g. api_key_helper)", %{dir: dir} do
      write_raw(dir, Jason.encode!(%{"apiKeyHelper" => "/usr/bin/helper"}))
      assert CredentialFreshness.check(dir, now_ms: @now) == :unknown
    end

    test "an OAuth blob without expiresAt is :unknown (can't tell)", %{dir: dir} do
      write_cred(dir, %{"accessToken" => "a"})
      assert CredentialFreshness.check(dir, now_ms: @now) == :unknown
    end

    test "undecodable json is :unknown", %{dir: dir} do
      write_raw(dir, "{not json")
      assert CredentialFreshness.check(dir, now_ms: @now) == :unknown
    end

    test "nil config_dir (legacy host-login, no CLAUDE_CONFIG_DIR) is :unknown" do
      assert CredentialFreshness.check(nil, now_ms: @now) == :unknown
    end
  end

  # #160 — status/2 adds the distinct :missing that check/2 collapses into :unknown.
  describe "status/2" do
    test "an ABSENT .credentials.json is :missing (logged out / never /login)", %{dir: dir} do
      # dir exists but no cred file written.
      assert CredentialFreshness.status(dir, now_ms: @now) == :missing
    end

    test "a fresh present token is :fresh", %{dir: dir} do
      write_cred(dir, %{"accessToken" => "a", "expiresAt" => @now + 3_600_000})
      assert CredentialFreshness.status(dir, now_ms: @now) == :fresh
    end

    test "an expired present token is {:stale, :expired}", %{dir: dir} do
      write_cred(dir, %{"accessToken" => "a", "expiresAt" => @now - 1})
      assert CredentialFreshness.status(dir, now_ms: @now) == {:stale, :expired}
    end

    test "a token within the skew window is {:stale, :expiring_soon}", %{dir: dir} do
      write_cred(dir, %{"accessToken" => "a", "expiresAt" => @now + 30_000})
      assert CredentialFreshness.status(dir, now_ms: @now, skew_ms: 60_000) ==
               {:stale, :expiring_soon}
    end

    test "a PRESENT but garbled file is :unknown (NOT :missing)", %{dir: dir} do
      write_raw(dir, "{not json")
      assert CredentialFreshness.status(dir, now_ms: @now) == :unknown
    end

    test "a present non-OAuth shape is :unknown (NOT :missing)", %{dir: dir} do
      write_raw(dir, Jason.encode!(%{"apiKeyHelper" => "/usr/bin/helper"}))
      assert CredentialFreshness.status(dir, now_ms: @now) == :unknown
    end

    test "nil config_dir is :unknown" do
      assert CredentialFreshness.status(nil) == :unknown
    end
  end

  describe "expires_at/1" do
    test "returns the OAuth expiresAt epoch ms when present", %{dir: dir} do
      write_cred(dir, %{"accessToken" => "a", "expiresAt" => @now + 3_600_000})
      assert CredentialFreshness.expires_at(dir) == @now + 3_600_000
    end

    test "is nil when the file is absent", %{dir: dir} do
      assert CredentialFreshness.expires_at(dir) == nil
    end

    test "is nil for a non-OAuth / garbled file", %{dir: dir} do
      write_raw(dir, "{not json")
      assert CredentialFreshness.expires_at(dir) == nil
    end

    test "is nil for nil config_dir" do
      assert CredentialFreshness.expires_at(nil) == nil
    end
  end

  describe "remind/3 — never blocks; warns + telemetry + meta on a stale token" do
    setup do
      ref = make_ref()
      parent = self()

      handler = "cred-fresh-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:ezagent, :cc, :credential_freshness, :stale],
        fn event, meas, meta, _ -> send(parent, {ref, event, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      {:ok, ref: ref}
    end

    test "an expired token returns degraded meta + emits telemetry", %{dir: dir, ref: ref} do
      write_cred(dir, %{"accessToken" => "a", "expiresAt" => @now - 1})
      uri = URI.parse("entity://system/agent/cc_worker-1")

      meta = CredentialFreshness.remind(uri, dir, now_ms: @now)

      assert meta == %{credential_stale: true, credential_stale_reason: :expired}
      assert_receive {^ref, [:ezagent, :cc, :credential_freshness, :stale], _meas, tmeta}
      assert tmeta.reason == :expired
      assert tmeta.agent_uri == uri
    end

    test "a fresh token returns empty meta and emits no telemetry", %{dir: dir, ref: ref} do
      write_cred(dir, %{"accessToken" => "a", "expiresAt" => @now + 3_600_000})
      uri = URI.parse("entity://system/agent/cc_worker-2")

      assert CredentialFreshness.remind(uri, dir, now_ms: @now) == %{}
      refute_receive {^ref, _, _, _}, 50
    end

    test ":unknown (missing) returns empty meta and emits no telemetry", %{dir: dir, ref: ref} do
      uri = URI.parse("entity://system/agent/cc_worker-3")
      assert CredentialFreshness.remind(uri, dir, now_ms: @now) == %{}
      refute_receive {^ref, _, _, _}, 50
    end
  end
end
