defmodule Ezagent.PluginCc.Template.CcCredentialGateLaunchTest do
  @moduledoc """
  chain B / #1096 (credential gap) — a fresh cc create whose per-agent config
  home materializes MARKER-complete but WITHOUT `.credentials.json` must
  FAIL FAST at the launch gate (`{:credential_not_materialized, _}`) rather than
  launch a doomed `claude` that boots "Not logged in" (exit-256), whose
  esr-bridge never joins and whose orchestrator ReadyGate hangs `:not_ready`.

  This is the sibling of `CcPtyAfterConfigDirTest` (which proves the ordering:
  when the credential IS present, `Pty.start/2` only fires after the home is
  materialized). Here the ONLY difference is the reference home carries no
  credential — and that flips the outcome from a launch to a loud decline. cc is
  a credentialled `:file` flavor, so its credential — not the completion marker —
  is the launchable signal (`HomeRuntime.config_dir_launchable?/2`).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCc.Template.CcAgent

  defp uniq, do: System.unique_integer([:positive])

  defp base_tmpl(agent_uri, target, ref_dir, cwd) do
    %{
      "class" => "cc.agent",
      "agent_uri" => URI.to_string(agent_uri),
      "cwd" => cwd,
      "config_dir" => ref_dir,
      # In production injected by `Kind.Template.provision_and_instantiate/4`.
      "allocated_config_dir" => target
    }
  end

  setup do
    agent_uri = URI.new!("entity://team-a/agent/cc-credgate-#{uniq()}")
    target = CcAgent.agent_config_dir(agent_uri)
    on_exit(fn -> File.rm_rf(target) end)

    cwd = Path.join(System.tmp_dir!(), "cc-cwd-#{uniq()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(cwd) end)

    {:ok, agent_uri: agent_uri, target: target, cwd: cwd}
  end

  test "fresh cc create with a credential-less home DECLINES the launch (fail-fast, no PTY)",
       ctx do
    # Reference home WITHOUT `.credentials.json` — the materialized per-agent home
    # will be marker-complete but credential-less.
    ref_dir = Path.join(System.tmp_dir!(), "cc-ref-nocred-#{uniq()}")
    File.mkdir_p!(ref_dir)
    File.write!(Path.join(ref_dir, "settings.json"), "SETTINGS")
    on_exit(fn -> File.rm_rf(ref_dir) end)

    tmpl = base_tmpl(ctx.agent_uri, ctx.target, ref_dir, ctx.cwd)

    result = CcAgent.instantiate("cc.agent", tmpl, URI.new!("workspace://team-a"))

    assert {:error, reason} = result

    assert inspect(reason) =~ "credential_not_materialized",
           "a credential-less cc home must fail-fast at the launch gate; got: #{inspect(reason)}"

    # No `claude` PTY was launched against the doomed home.
    refute Ezagent.Domain.Pty.alive?(ctx.agent_uri),
           "no PtyServer must be alive — the launch was declined before Pty.start"
  end

  test "a DeepSeek-provider cc agent is NOT declined for lacking a credential (#1324)", ctx do
    # DeepSeek cc agents authenticate via DEEPSEEK_API_KEY (env), not a
    # `.credentials.json` OAuth login, so the credential gate must NOT fire —
    # even against a credential-less home.
    System.put_env("DEEPSEEK_API_KEY", "sk-test-deepseek")
    on_exit(fn -> System.delete_env("DEEPSEEK_API_KEY") end)

    ref_dir = Path.join(System.tmp_dir!(), "cc-ref-ds-#{uniq()}")
    File.mkdir_p!(ref_dir)
    File.write!(Path.join(ref_dir, "settings.json"), "SETTINGS")
    on_exit(fn -> File.rm_rf(ref_dir) end)

    tmpl =
      ctx.agent_uri
      |> base_tmpl(ctx.target, ref_dir, ctx.cwd)
      |> Map.put("provider", "deepseek")

    result = CcAgent.instantiate("cc.agent", tmpl, URI.new!("workspace://team-a"))

    refute match?({:error, {:credential_not_materialized, _}}, result),
           "a DeepSeek-provider cc agent must NOT be gated on a `.credentials.json`; got: " <>
             inspect(result)

    _ = Ezagent.Domain.Pty.stop(ctx.agent_uri)
  end

  test "fresh cc create WITH a credential launches (control — only the credential differs)",
       ctx do
    # Same setup, but the reference home carries `.credentials.json` → launchable.
    ref_dir = Path.join(System.tmp_dir!(), "cc-ref-cred-#{uniq()}")
    File.mkdir_p!(ref_dir)
    File.write!(Path.join(ref_dir, ".credentials.json"), "TOKEN")
    File.write!(Path.join(ref_dir, "settings.json"), "SETTINGS")
    on_exit(fn -> File.rm_rf(ref_dir) end)

    tmpl = base_tmpl(ctx.agent_uri, ctx.target, ref_dir, ctx.cwd)

    assert {:ok, [_uri], _meta} =
             CcAgent.instantiate("cc.agent", tmpl, URI.new!("workspace://team-a"))

    # The credential was materialized into the per-agent home BEFORE launch.
    assert File.exists?(Path.join(ctx.target, ".credentials.json"))

    _ = Ezagent.Domain.Pty.stop(ctx.agent_uri)
  end
end
