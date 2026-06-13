defmodule Ezagent.Invariants.CredentialAdapterContractTest do
  @moduledoc """
  #17 PR-A invariant — a Template Class that implements ANY
  `Ezagent.Agent.CredentialAdapter` declarative callback MUST implement ALL of them
  (`credential_env_var/0`, `credential_relpaths/0`, `auth_failure_signals/0`).

  A flavor that declares WHERE creds live but not HOW to detect expiry (or vice-versa) is
  an incomplete credential lifecycle. Mirrors the extension-callback all-or-none gate.

  Credential-less flavors (curl/echo/np) implement NONE — that is allowed.
  """
  use ExUnit.Case, async: true

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  @file_callbacks Ezagent.Agent.CredentialAdapter.declarative_callbacks()
  @slice_callbacks Ezagent.Agent.CredentialSliceAdapter.declarative_callbacks()

  test "every Template Class implements all-or-none of the credential-adapter callbacks" do
    classes = template_class_modules()

    refute classes == [],
           "no Template Classes found — umbrella app loading is broken; test is vacuous"

    violations =
      Enum.flat_map(classes, fn mod ->
        Code.ensure_loaded(mod)

        implemented =
          Enum.filter(@file_callbacks, fn {name, arity} ->
            function_exported?(mod, name, arity)
          end)

        cond do
          implemented == [] -> []
          length(implemented) == length(@file_callbacks) -> []
          true -> [{mod, implemented, @file_callbacks -- implemented}]
        end
      end)

    assert violations == [],
           "Template Classes with PARTIAL credential-adapter opt-in: #{inspect(violations)}"
  end

  test "every Template Class implements all-or-none of the slice credential callbacks" do
    classes = template_class_modules()

    violations =
      Enum.flat_map(classes, fn mod ->
        Code.ensure_loaded(mod)

        implemented =
          Enum.filter(@slice_callbacks, fn {name, arity} ->
            function_exported?(mod, name, arity)
          end)

        cond do
          implemented == [] -> []
          length(implemented) == length(@slice_callbacks) -> []
          true -> [{mod, implemented, @slice_callbacks -- implemented}]
        end
      end)

    assert violations == [],
           "Template Classes with PARTIAL slice credential opt-in: #{inspect(violations)}"
  end

  test "cc + codex DO declare a full credential adapter (non-vacuous)" do
    for mod <- [Ezagent.PluginCc.Template.CcAgent, Ezagent.PluginCodex.Template.CodexAgent] do
      assert Ezagent.Agent.CredentialAdapter.credentialled?(mod),
             "#{inspect(mod)} must implement the full credential adapter"
    end

    assert Ezagent.PluginCc.Template.CcAgent.credential_env_var() == "CLAUDE_CONFIG_DIR"
    assert Ezagent.PluginCc.Template.CcAgent.credential_relpaths() == [".credentials.json"]
    assert Ezagent.PluginCodex.Template.CodexAgent.credential_env_var() == "CODEX_HOME"
    assert "auth.json" in Ezagent.PluginCodex.Template.CodexAgent.credential_relpaths()
  end

  test "curl declares the slice credential adapter instead of a file adapter" do
    refute Ezagent.Agent.CredentialAdapter.credentialled?(Ezagent.PluginCurlAgent.Template)
    assert Ezagent.Agent.CredentialSliceAdapter.credentialled?(Ezagent.PluginCurlAgent.Template)
    assert Ezagent.PluginCurlAgent.Template.credential_slice() == :api_keys
  end

  defp template_class_modules do
    apps = discover_umbrella_apps()
    for app <- apps, do: Application.load(app)

    for app <- apps,
        {:ok, modules} <- [:application.get_key(app, :modules)],
        mod <- modules,
        implements_kind_template?(mod) do
      mod
    end
  end

  defp discover_umbrella_apps do
    apps_dir = Path.expand("../../../../", __DIR__) |> Path.join("apps")

    case File.ls(apps_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn name ->
          File.dir?(Path.join(apps_dir, name)) and
            File.exists?(Path.join([apps_dir, name, "mix.exs"]))
        end)
        |> Enum.map(&String.to_atom/1)

      _ ->
        []
    end
  end

  defp implements_kind_template?(mod) do
    Code.ensure_loaded(mod)
    behaviours = mod.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    Ezagent.Kind.Template in behaviours
  rescue
    _ -> false
  end
end
