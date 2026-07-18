defmodule Ezagent.Agent.Architecture.CredentialAdapterCompletenessTest do
  @moduledoc """
  Gate: a credential-bearing `Ezagent.Agent.CredentialAdapter` MUST export
  `host_login_dir/0`.

  ## The bug class this closes

  `host_login_dir/0` is in `@optional_callbacks` (`credential_adapter.ex:86`), so
  omitting it compiles clean — no warning, no dialyzer complaint. But
  `CredentialAdapter.host_login_source_dir/1` gates on
  `function_exported?(mod, :host_login_dir, 0)`. An adapter that forgets the
  delegate therefore resolves to `:none`, `HostLoginAdopt.ensure_installer_source/3`
  **silently no-ops**, and the agent's materialized config home never receives a
  credential file. The agent boots "Not logged in", 401s, never joins its
  transport bridge, and hangs at `:not_ready` forever.

  That is exactly #1309/#1311: `CcHeadlessAgent` delegated the whole
  CredentialAdapter interface to `CcAgent` and omitted this one callback. Its
  commit message: *"This is the deterministic blocker behind the canary
  '@orchestrator never replies'."*

  `@optional_callbacks` + `function_exported?` is a silent-no-op factory. It has
  now cost this project two production incidents. The callback stays optional (a
  credential-LESS adapter has no host login), but a credential-BEARING one must
  provide it, and that is checkable.

  Forensics: `docs/together/2026-07-09/cc-orchestrator-create-blocking-rootcause.zh_cn.md`
  """
  use ExUnit.Case, async: true

  @adapters [
    Ezagent.PluginCc.Template.CcAgent,
    Ezagent.PluginCc.Template.CcHeadlessAgent,
    # cc-custom / cc-headless-custom (PR-2/3): env-var auth per selected backend
    # profile, NO on-disk credential — `credential_relpaths/0 == []`, so
    # `credential_bearing?/1` filters them out of the host_login_dir/0
    # requirement below. Listed here only so the "not silently stale"
    # cross-check stays exhaustive.
    Ezagent.PluginCc.Template.CcCustomAgent,
    Ezagent.PluginCc.Template.CcHeadlessCustomAgent,
    Ezagent.PluginCodex.Template.CodexAgent,
    Ezagent.PluginCodex.Template.CodexRemoteAgent
  ]

  test "every credential-bearing CredentialAdapter exports host_login_dir/0" do
    violations =
      for module <- @adapters,
          Code.ensure_loaded?(module),
          credential_bearing?(module),
          not function_exported?(module, :host_login_dir, 0) do
        module
      end

    assert violations == [],
           """
           These CredentialAdapters declare `credential_relpaths/0` but do not export
           the OPTIONAL `host_login_dir/0` callback:

           #{Enum.map_join(violations, "\n", &("  * " <> inspect(&1)))}

           `CredentialAdapter.host_login_source_dir/1` gates on
           `function_exported?(mod, :host_login_dir, 0)`, so the omission makes
           `HostLoginAdopt.ensure_installer_source/3` a SILENT no-op: the agent's config
           home never receives credentials, `claude` boots "Not logged in", the transport
           bridge never joins, and the agent hangs at `:not_ready` forever — with no error
           logged anywhere. (#1309/#1311.)

           Delegate it, e.g.:

               @impl Ezagent.Agent.CredentialAdapter
               def host_login_dir, do: Ezagent.PluginCc.Template.CcAgent.host_login_dir()
           """
  end

  test "the adapter list is not silently stale" do
    # A new CredentialAdapter that nobody adds to @adapters would make the gate
    # above vacuously green. Cross-check against the source tree.
    declared =
      Path.wildcard(Path.join([umbrella_root(), "apps", "*", "lib", "**", "*.ex"]))
      |> Enum.filter(&(File.read!(&1) =~ "@behaviour Ezagent.Agent.CredentialAdapter"))
      |> length()

    assert declared == length(@adapters),
           "found #{declared} CredentialAdapter implementations but @adapters lists " <>
             "#{length(@adapters)} — add the new one (and give it host_login_dir/0)"
  end

  defp credential_bearing?(module) do
    function_exported?(module, :credential_relpaths, 0) and module.credential_relpaths() != []
  end

  defp umbrella_root, do: Path.expand("../../../..", __DIR__)
end
