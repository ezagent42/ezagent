defmodule Ezagent.Kind.TemplateNamespaceTest do
  @moduledoc """
  PR-3 — `Ezagent.Kind.Template.namespace_of/1` resolves the config_dir path
  namespace from the Template Class (boot-safe: the class module is the receiver
  of every `instantiate/3` call, present even when template_data lacks a flavor
  key). Prefers the optional `config_dir_namespace/0` callback; otherwise derives
  it from `template_name/0` by stripping the `.agent` suffix.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Kind.Template

  defmodule WithCallback do
    def template_name, do: "cc.agent"
    def config_dir_namespace, do: "cc"
  end

  defmodule WithoutCallback do
    def template_name, do: "demo.agent"
  end

  defmodule PlainName do
    def template_name, do: "curl"
  end

  test "prefers the config_dir_namespace/0 callback when exported" do
    assert Template.namespace_of(WithCallback) == "cc"
  end

  test "derives from template_name by stripping the .agent suffix when no callback" do
    assert Template.namespace_of(WithoutCallback) == "demo"
  end

  test "a template_name without a .agent suffix is used as-is" do
    assert Template.namespace_of(PlainName) == "curl"
  end
end
