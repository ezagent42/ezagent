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

  The fix: when `respawn_data` carries a test/E2E `credential_source` (only the
  E2E provisioner sets it — production users log in interactively), the respawn
  chokepoint re-runs the refresh-if-expired provisioner into the source's resolved
  config_home BEFORE relaunch.

  ## Two layers of coverage

  1. UNIT (`Spawn.reprovision_source_credential/3` + `…from_respawn_data/2`) —
     the extracted refresh-if-expired helper with directly-injected http/clock.
  2. PATH-LEVEL (codex #719 HIGH) — proves the field actually REACHES the persisted
     `respawn_template_data` via the REAL content→data chokepoint
     (`Ezagent.Entity.AgentTemplate.to_template_data/2`, the cc
     `template_data_extra/1` producer), AND that an EXPIRED source is refreshed when
     driven through the public `CcAgent.ensure_subprocess_alive/2` rehydration
     boundary (not just the extracted helper). The OAuth http_post + clock are
     injected via the established `:ezagent_plugin_cc` app-env seam so the test never
     hits the network or rotates a real token.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCc.Template.CcAgent
  alias Ezagent.PluginCc.Template.CcAgent.Spawn
  alias Ezagent.Entity.AgentTemplate

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

  # An OAuth blob already past its `expiresAt`, carrying a refresh token.
  defp expired_oauth(now),
    do: %{"accessToken" => "OLD-ACCESS", "refreshToken" => "RT-1", "expiresAt" => now - 10_000}

  # The injected token endpoint response: a refreshed access/refresh token pair.
  defp refresh_http_post do
    fn _url, _ct, _body ->
      {:ok, 200,
       Jason.encode!(%{
         "access_token" => "FRESH-ACCESS",
         "refresh_token" => "RT-2",
         "expires_in" => 3600
       })}
    end
  end

  describe "reprovision_source_credential/3 (refresh-if-expired helper)" do
    test "an EXPIRED source token is refreshed into the config_home" do
      config_home = tmp("cc-src-home")
      source = tmp("cc-src-login")
      source_path = Path.join(source, ".credentials.json")

      now = 1_000_000

      File.write!(source_path, Jason.encode!(%{"claudeAiOauth" => expired_oauth(now)}))
      # Stale (expired) copy already in the config_home from a prior run.
      write_cred!(config_home, expired_oauth(now))

      assert :ok =
               Spawn.reprovision_source_credential(config_home, source_path,
                 now_ms: now,
                 http_post: refresh_http_post()
               )

      # The config_home credential is refreshed (the fresh access token), proving it
      # persisted + was re-provisioned across the (simulated) respawn.
      assert read_cred(config_home)["claudeAiOauth"]["accessToken"] == "FRESH-ACCESS"
      # The source itself was rotated-and-written-back (keeps it valid for the next run).
      assert source_path |> File.read!() |> Jason.decode!() |> get_in(["claudeAiOauth", "accessToken"]) ==
               "FRESH-ACCESS"
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

  describe "maybe_reprovision_source_from_respawn_data/2 (best-effort)" do
    @agent_uri URI.new!("entity://team-a/agent/cc_srcrespawn-1")

    test "respawn_data without credential_source does not attempt provisioning" do
      assert :ok =
               Spawn.maybe_reprovision_source_from_respawn_data(@agent_uri, %{"cwd" => "/tmp"})
    end

    test "credential_source present but absent source file is logged + swallowed (no crash)" do
      assert :ok =
               Spawn.maybe_reprovision_source_from_respawn_data(@agent_uri, %{
                 "cwd" => "/tmp",
                 "credential_source" => "/nonexistent/.credentials.json",
                 "agent_config_dir" => System.tmp_dir!()
               })
    end
  end

  # ── PATH-LEVEL (codex #719 HIGH) ──────────────────────────────────────────
  #
  # The codex finding: the respawn helper only fires when respawn_data carries a
  # top-level `credential_source`, but NO repository producer emitted that field —
  # so a source agent created through the real content→data→sandbox path hit the
  # nil branch and relaunched with the STALE on-disk credential. These tests close
  # that gap: they exercise the REAL producer + the REAL rehydration entrypoint.
  describe "path-level: credential_source reaches respawn_template_data + fires on respawn" do
    setup do
      {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)
      :ok
    end

    test "the cc content→data chokepoint (to_template_data/2) emits credential_source" do
      # This is the data map that the cc plugin's instantiate/3 receives and that the
      # spawn path persists VERBATIM as respawn_template_data (spawn.ex `tmpl_with_dir`).
      source = tmp("cc-src-login")
      source_path = Path.join(source, ".credentials.json")
      File.write!(source_path, Jason.encode!(%{"claudeAiOauth" => expired_oauth(1_000_000)}))

      config_dir = tmp("cc-src-home")
      agent_uri = URI.new!("entity://team-a/agent/cc_pathlvl-#{uniq()}")

      content = %{
        flavor: "cc",
        project_cwd: System.tmp_dir!(),
        config_dir: config_dir,
        credential_source: source_path
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, agent_uri)

      # The REAL producer wired the source path into the (string-keyed) Template-Class
      # data — NOT a key the new helper or its tests synthesize.
      assert Map.get(data, "credential_source") == source_path,
             "to_template_data/2 must emit credential_source so it persists into " <>
               "respawn_template_data (codex #719 HIGH — no producer existed before)"
    end

    test "an EXPIRED source is refreshed through ensure_subprocess_alive/2 on respawn" do
      now = 1_000_000

      # Inject the OAuth http_post + clock via the app-env seam the respawn path reads
      # (no network, no real-token rotation). PRODUCTION reads `[]` → real httpc/clock.
      Application.put_env(:ezagent_plugin_cc, :source_reprovision_opts,
        now_ms: now,
        http_post: refresh_http_post()
      )

      on_exit(fn -> Application.delete_env(:ezagent_plugin_cc, :source_reprovision_opts) end)

      source = tmp("cc-src-login")
      source_path = Path.join(source, ".credentials.json")
      File.write!(source_path, Jason.encode!(%{"claudeAiOauth" => expired_oauth(now)}))

      # The source agent's config_home holds the STALE (expired) credential from create.
      config_home = tmp("cc-src-home")
      write_cred!(config_home, expired_oauth(now))

      # A fresh URI with NO grant row → the §5.1 revocation gate lets the respawn THROUGH
      # (proven by cc_agent_cascade_materialize_test) and, in MIX_ENV=test, Domain.Pty
      # short-circuits `:exec.run` so no real `claude` launches.
      agent_uri = URI.new!("entity://team-a/agent/cc_srcalive-#{uniq()}")
      on_exit(fn -> File.rm_rf(CcAgent.agent_config_dir(agent_uri)) end)

      # respawn_template_data carrying the credential_source the REAL producer emits,
      # plus the config_home (top-precedence `agent_config_dir` key resolve_config_home
      # reads) and the required cwd.
      respawn_data = %{
        "cwd" => System.tmp_dir!(),
        "agent_config_dir" => config_home,
        "credential_source" => source_path
      }

      assert :ok = CcAgent.ensure_subprocess_alive(agent_uri, respawn_data)

      # The expired credential in the source agent's OWN config_home was refreshed
      # BEFORE relaunch — i.e. the respawn carried the source key all the way through
      # ensure_subprocess_alive → respawn_subprocess → reprovision (codex #719 HIGH).
      assert read_cred(config_home)["claudeAiOauth"]["accessToken"] == "FRESH-ACCESS",
             "ensure_subprocess_alive/2 must re-provision the source's expired credential " <>
               "on respawn — got the stale OLD-ACCESS token"

      # Cleanup the stub PtyServer started in test_mode.
      _ = Ezagent.Domain.Pty.stop(agent_uri)
    end

    test "a respawn WITHOUT credential_source leaves the on-disk credential untouched" do
      # The production interactive-login path: no credential_source → reprovision is a
      # no-op; whatever is on disk relaunches as-is (the pre-#719 behavior for non-E2E).
      Application.put_env(:ezagent_plugin_cc, :source_reprovision_opts,
        now_ms: 1_000_000,
        http_post: fn _u, _c, _b -> flunk("must NOT provision without a credential_source") end
      )

      on_exit(fn -> Application.delete_env(:ezagent_plugin_cc, :source_reprovision_opts) end)

      config_home = tmp("cc-prod-home")
      write_cred!(config_home, expired_oauth(1_000_000))

      agent_uri = URI.new!("entity://team-a/agent/cc_prodalive-#{uniq()}")
      on_exit(fn -> File.rm_rf(CcAgent.agent_config_dir(agent_uri)) end)

      respawn_data = %{"cwd" => System.tmp_dir!(), "agent_config_dir" => config_home}

      assert :ok = CcAgent.ensure_subprocess_alive(agent_uri, respawn_data)

      assert read_cred(config_home)["claudeAiOauth"]["accessToken"] == "OLD-ACCESS"

      _ = Ezagent.Domain.Pty.stop(agent_uri)
    end
  end
end
