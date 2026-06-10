defmodule Ezagent.PluginCc.Template.CcSourceRespawnCredentialTest do
  @moduledoc """
  §5.B follow-up (c) — the SOURCE agent's `config_dir` credential must be DURABLE
  across the source agent's OWN respawns.

  The source agent (the credential origin the #17 cascade copies FROM) gets its
  `.credentials.json` provisioned by the test/E2E provisioner
  (`CredentialAdapter.refresh_test_credentials/3`, refresh-if-expired). The
  production respawn path (`Spawn.respawn_subprocess/2`) deliberately does NOT
  re-materialize the config_dir — it relaunches the PTY against the on-disk dir.
  Before this fix it therefore did NOT re-provision/refresh the source's
  credential either, so an OAuth token that expired between create and respawn
  stayed expired → the source agent came back up mute (and downstream cascade
  members inherited a stale token).

  The fix: when `respawn_data` carries a test/E2E `:credential_source` (only the
  E2E provisioner sets it — production users log in interactively), the respawn
  chokepoint re-runs the refresh-if-expired provisioner into the source's resolved
  config_home BEFORE relaunch. This test injects the OAuth `http_post` + clock so
  it never hits the network or rotates a real token.
  """
  use ExUnit.Case, async: false

  alias Ezagent.PluginCc.Template.CcAgent.Spawn

  defp uniq, do: System.unique_integer([:positive])

  defp tmp(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write_cred!(dir, oauth) do
    File.write!(Path.join(dir, ".credentials.json"), Jason.encode!(%{"claudeAiOauth" => oauth}))
  end

  defp read_cred(dir) do
    dir |> Path.join(".credentials.json") |> File.read!() |> Jason.decode!()
  end

  describe "respawn re-provisions the source credential (refresh-if-expired)" do
    test "an EXPIRED source token is refreshed into the config_home on respawn" do
      config_home = tmp("cc-src-home")
      source = tmp("cc-src-login")
      source_path = Path.join(source, ".credentials.json")

      now = 1_000_000

      # Source token is already expired (expiresAt in the past) and carries a
      # refresh token — the provisioner must refresh it.
      File.write!(
        source_path,
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "OLD-ACCESS",
            "refreshToken" => "RT-1",
            "expiresAt" => now - 10_000
          }
        })
      )

      # Stale (expired) copy already in the config_home from a prior run.
      write_cred!(config_home, %{
        "accessToken" => "OLD-ACCESS",
        "refreshToken" => "RT-1",
        "expiresAt" => now - 10_000
      })

      http_post = fn _url, _ct, _body ->
        {:ok, 200,
         Jason.encode!(%{
           "access_token" => "FRESH-ACCESS",
           "refresh_token" => "RT-2",
           "expires_in" => 3600
         })}
      end

      assert :ok =
               Spawn.reprovision_source_credential(config_home, source_path,
                 now_ms: now,
                 http_post: http_post
               )

      # The config_home credential is refreshed (the fresh access token), proving
      # it persisted + was re-provisioned across the (simulated) respawn.
      refreshed = read_cred(config_home)["claudeAiOauth"]
      assert refreshed["accessToken"] == "FRESH-ACCESS"

      # The source itself was rotated-and-written-back (keeps it valid for the next run).
      rotated_source = source_path |> File.read!() |> Jason.decode!()
      assert rotated_source["claudeAiOauth"]["accessToken"] == "FRESH-ACCESS"
    end

    test "a still-valid source token is copied as-is (no network call) and persists" do
      config_home = tmp("cc-src-home")
      source = tmp("cc-src-login")
      source_path = Path.join(source, ".credentials.json")

      now = 1_000_000

      File.write!(
        source_path,
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "VALID-ACCESS",
            "refreshToken" => "RT-1",
            "expiresAt" => now + 3_600_000
          }
        })
      )

      refute_called = fn _url, _ct, _body ->
        flunk("must NOT call the OAuth endpoint for a still-valid source token")
      end

      assert :ok =
               Spawn.reprovision_source_credential(config_home, source_path,
                 now_ms: now,
                 http_post: refute_called
               )

      assert read_cred(config_home)["claudeAiOauth"]["accessToken"] == "VALID-ACCESS"
    end

    test "nil credential_source / config_home is a no-op (production interactive-login path)" do
      assert :ok = Spawn.reprovision_source_credential(nil, "/whatever/.credentials.json", [])
      assert :ok = Spawn.reprovision_source_credential("/whatever", nil, [])
    end
  end

  describe "respawn_subprocess threads the credential_source through" do
    @agent_uri URI.new!("entity://team-a/agent/cc_srcrespawn-1")

    test "respawn_data without :credential_source does not attempt provisioning" do
      # No :credential_source key → reprovision is skipped; respawn proceeds to the
      # PTY launch path. (We can't fully launch a real PTY here, but we assert the
      # provisioning step is a no-op by calling the extracted helper directly.)
      assert :ok =
               Spawn.maybe_reprovision_source_from_respawn_data(@agent_uri, %{"cwd" => "/tmp"})
    end

    test "respawn_data with :credential_source but absent source file is a no-op (does not crash respawn)" do
      # credential_source present but the source file does not exist → the
      # provisioner returns an error which the respawn step LOGS + swallows
      # (best-effort: a missing E2E source must not crash-loop the respawn).
      assert :ok =
               Spawn.maybe_reprovision_source_from_respawn_data(@agent_uri, %{
                 "cwd" => "/tmp",
                 "credential_source" => "/nonexistent/.credentials.json",
                 "agent_config_dir" => System.tmp_dir!()
               })
    end
  end
end
