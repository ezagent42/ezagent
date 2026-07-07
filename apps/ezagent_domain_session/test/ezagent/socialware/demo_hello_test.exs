defmodule Ezagent.Socialware.Demo.HelloTest do
  @moduledoc """
  Shape gate for the LEGACY single-agent fixture branch of
  `Ezagent.Socialware.Demo.Hello.manifest_attrs/1` (the `:role_name` option) —
  the pure-`code` shape older materialization tests still use.

  The reference (3-role) shape is now CONFIG shipped in
  `apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml`, so its drift gate
  lives in `ezagent_web` (where the shipping app + file are loaded). This
  domain_session-local test cannot see the web-shipped file (`:ezagent_web` is
  not a dep here), so it locks only the branch that stays code in this layer.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Socialware.Demo.Hello

  test "legacy :role_name branch emits the single-agent fixture shape" do
    attrs =
      Hello.manifest_attrs(name: "hello-fixture", recipe_name: "np", role_name: "hello-helper")

    assert attrs["name"] == "hello-fixture"

    assert attrs["roles"] == [
             %{
               "role_name" => "hello-helper",
               "fill" => "agent",
               "recipe" => "np",
               "flavor" => "py"
             }
           ]

    assert attrs["prompt_templates"] == %{"hello" => "Say hello: {body}"}

    assert [
             %{
               "matcher" => %{"type" => "always"},
               "receivers" => ["hello-helper"],
               "prompt_template_ref" => "hello"
             }
           ] = attrs["routing_rules"]
  end
end
