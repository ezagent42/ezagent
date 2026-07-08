defmodule Ezagent.Invariants.PluginConfigDirResourceTypesTest do
  use ExUnit.Case, async: false

  @moduletag :umbrella_only

  alias Ezagent.Resource.FsResolver
  alias Ezagent.URI, as: EzURI

  @plugins [
    EzagentPluginCc.Application,
    EzagentPluginCodex.Application,
    EzagentPluginPy.Application
  ]

  defp scope(ws), do: %{workspace: ws}

  test "config-dir-owning plugin templates declare matching resource_types/0 entries" do
    missing =
      for plugin <- @plugins,
          namespace <- expected_namespaces(plugin),
          expected_type = "#{namespace}-agents",
          not Map.has_key?(resource_type_map(plugin), expected_type),
          do: {plugin, expected_type}

    assert missing == []
  end

  test "all plugin-declared config-dir resource types resolve through FsResolver" do
    failures =
      for plugin <- @plugins,
          namespace <- expected_namespaces(plugin),
          type = "#{namespace}-agents",
          uri = EzURI.resource("system", type, "probe"),
          reduce: [] do
        acc ->
          case FsResolver.resolve(uri, scope("system")) do
            {:ok, _path} -> acc
            other -> [{plugin, type, other} | acc]
          end
      end

    assert Enum.reverse(failures) == []
  end

  defp expected_namespaces(plugin) do
    plugin.template_classes()
    |> Enum.filter(&config_dir_template?/1)
    |> Enum.map(&Ezagent.Kind.Template.namespace_of/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp config_dir_template?(template_class) do
    (Code.ensure_loaded?(template_class) and
       function_exported?(template_class, :config_dir_namespace, 0)) or
      credentialled_template?(template_class)
  end

  defp credentialled_template?(template_class) do
    Code.ensure_loaded?(Ezagent.Agent.CredentialAdapter) and
      function_exported?(Ezagent.Agent.CredentialAdapter, :credentialled?, 1) and
      Ezagent.Agent.CredentialAdapter.credentialled?(template_class)
  rescue
    _ -> false
  end

  defp resource_type_map(plugin), do: Map.new(plugin.resource_types())
end
