defmodule Ezagent.Socialware.SeedEmptyCredentialStoreTest do
  @moduledoc """
  Runtime companion to `boot_no_credentialled_agent_spawn_test.exs`.

  Property (a) of the boot credential-independence gate: **the seed entry points
  SUCCEED with an EMPTY credential store.** The static scan proves no seed path
  STARTS a credentialled agent; it cannot prove a seed path does not merely READ
  a credential (e.g. a future `SocialwareSeed` that opens `.credentials.json` and
  crashes when it is absent). This test closes that half: it runs the seed entry
  points with every credential source emptied — host login dirs
  (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`) pointed at an empty temp dir, no
  `.credentials.json` — and asserts they return cleanly.

  Deliberately NARROW (spec §3 Q2(a): near-vacuous today is fine — it is a
  regression lock, same as the static gate). It does NOT boot the full
  supervision tree and does NOT enumerate started agents: under `MIX_ENV=test`
  the cc plugin's `after_boot/0` seeds a credentialled `main` orchestrator, which
  would pollute any runtime agent enumeration (see the sibling gate's moduledoc).
  This app (`ezagent_domain_session`) does not depend on the cc plugin, so no
  credentialled agent is booted here.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Home.SocialwareSeed
  alias Ezagent.Socialware.ManifestSeed

  @cred_env_vars ~w(CLAUDE_CONFIG_DIR CODEX_HOME)

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "ezagent-empty-cred-seed-#{System.unique_integer([:positive])}"
      )

    # Point every host-login credential dir at an EMPTY temp dir (no
    # `.credentials.json`) and restore the prior environment afterwards.
    empty_login = Path.join(base, "empty-login")
    File.mkdir_p!(empty_login)

    prior = for v <- @cred_env_vars, into: %{}, do: {v, System.get_env(v)}
    for v <- @cred_env_vars, do: System.put_env(v, empty_login)

    on_exit(fn ->
      Enum.each(prior, fn
        {v, nil} -> System.delete_env(v)
        {v, val} -> System.put_env(v, val)
      end)

      File.rm_rf(base)
    end)

    {:ok, base: base}
  end

  test "SocialwareSeed.seed!/1 deploy-copies packages with no credential present", %{base: base} do
    source = Path.join(base, "src")
    dest = Path.join(base, "deploy")
    File.mkdir_p!(Path.join(source, "demo-pkg"))
    File.write!(Path.join([source, "demo-pkg", "manifest.yaml"]), "name: demo-pkg\n")

    assert :ok = SocialwareSeed.seed!(source: source, dest: dest)

    assert File.dir?(Path.join(dest, "demo-pkg")),
           "the deploy-seed copy must run without a credential store"
  end

  test "ManifestSeed.scan_all!/1 sweeps the seed dir with no credential present", %{base: base} do
    # Force the boot scan ON (it is a no-op in :test by default) and point it at
    # an empty deploy dir so the scan lane runs end-to-end (enabled? → dir? →
    # sweep → []) without any manifest publish that would need a Repo. The point
    # is that the boot scan ENTRY requires no credential.
    deploy_dir = Path.join(base, "socialware-empty")
    File.mkdir_p!(deploy_dir)

    prior = Application.get_env(:ezagent_domain_session, :socialware_manifest_boot_scan)
    Application.put_env(:ezagent_domain_session, :socialware_manifest_boot_scan, true)

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:ezagent_domain_session, :socialware_manifest_boot_scan)
        val -> Application.put_env(:ezagent_domain_session, :socialware_manifest_boot_scan, val)
      end
    end)

    assert ManifestSeed.enabled?()
    assert :ok = ManifestSeed.scan_all!(deploy_dir: deploy_dir)
  end
end
