defmodule Ezagent.Credential.HomeRuntimeLaunchableTest do
  @moduledoc """
  chain B / #1096 — `HomeRuntime.config_dir_launchable?/2` must NOT bless a
  marker-complete-but-credential-less per-agent home for a credentialled
  `:file` flavor. claude reads `CLAUDE_CONFIG_DIR` (which OVERRIDES its
  `~/.claude` HOME lookup), so such a home boots "Not logged in" (exit-256) and
  its esr-bridge never joins. The credential — not the completion marker — is
  the launchable signal for credentialled flavors; the marker alone is a LIE.

  A credential-LESS flavor (the deepseek `:slice` `curl.agent`, `np`, `echo`)
  keeps no credential file, so the completion marker IS its launchable signal —
  it must NOT be failed for lacking a `.credentials.json`.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Credential.HomeRuntime

  @marker HomeRuntime.config_complete_marker()

  # A credentialled `:file` flavor Template Class (the cc/codex shape): it
  # implements the full `Ezagent.Agent.CredentialAdapter` declarative group.
  defmodule CredentialledFlavor do
    @behaviour Ezagent.Agent.CredentialAdapter
    @impl true
    def credential_env_var, do: "FAKE_CONFIG_DIR"
    @impl true
    def credential_relpaths, do: [".credentials.json"]
    @impl true
    def secret_relpaths, do: [".credentials.json"]
    @impl true
    def auth_failure_signals, do: []
  end

  # A credential-LESS flavor (deepseek `:slice` / curl / np / echo shape): it
  # implements NONE of the declarative credential callbacks.
  defmodule CredentialLessFlavor do
  end

  defp tmp(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write_marker(dir), do: File.write!(Path.join(dir, @marker), "ok\n")
  defp write_cred(dir), do: File.write!(Path.join(dir, ".credentials.json"), "TOKEN")

  describe "credentialled :file flavor (cc/codex) — credential is the launchable signal" do
    test "marker present but NO credential is NOT launchable (the marker-lies bug)" do
      dir = tmp("cred-marker-only")
      write_marker(dir)

      refute HomeRuntime.config_dir_launchable?(dir, CredentialledFlavor),
             "a marker-complete home WITHOUT .credentials.json must not be launchable — " <>
               "claude would boot 'Not logged in' (chain B / #1096)"
    end

    test "credential present is launchable (marker + credential)" do
      dir = tmp("cred-both")
      write_marker(dir)
      write_cred(dir)

      assert HomeRuntime.config_dir_launchable?(dir, CredentialledFlavor)
    end

    test "credential present WITHOUT a marker is launchable (operator interactive login)" do
      dir = tmp("cred-no-marker")
      write_cred(dir)

      assert HomeRuntime.config_dir_launchable?(dir, CredentialledFlavor),
             "an operator-provisioned home carrying a credential is launchable even " <>
               "without the completion marker"
    end

    test "empty dir is NOT launchable" do
      dir = tmp("cred-empty")
      refute HomeRuntime.config_dir_launchable?(dir, CredentialledFlavor)
    end
  end

  describe "credential-less flavor (deepseek :slice / curl / np) — marker is the launchable signal" do
    test "marker present (no credential file) IS launchable — never failed for lacking a credential" do
      dir = tmp("nocred-marker")
      write_marker(dir)

      assert HomeRuntime.config_dir_launchable?(dir, CredentialLessFlavor),
             "a credential-less flavor keeps no .credentials.json; the completion marker " <>
               "is its launchable signal and it must not be gated on a credential"
    end

    test "no marker is NOT launchable" do
      dir = tmp("nocred-empty")
      refute HomeRuntime.config_dir_launchable?(dir, CredentialLessFlavor)
    end
  end

  test "nil config home is never launchable" do
    refute HomeRuntime.config_dir_launchable?(nil, CredentialledFlavor)
    refute HomeRuntime.config_dir_launchable?(nil, CredentialLessFlavor)
  end
end
