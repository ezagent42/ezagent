defmodule EzagentWeb.HelloManifestDriftTest do
  @moduledoc """
  Anti-drift gate for the shipped hello deploy-seed manifest
  (`apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml`).

  Since the sw-home migration the hello reference (3-role) manifest is CONFIG,
  not code — production publishes it through the deploy-seed lane
  (`Ezagent.Home.SocialwareSeed` copy → `Ezagent.Socialware.ManifestSeed`
  scan/publish), and `Ezagent.Socialware.Demo.Hello.manifest_attrs/0` (the test
  driver) loads the SAME file. This test freezes the authoritative shape (the
  retired `reference_manifest_attrs("hello", "np")` code map, post-parse
  representation) so a YAML edit that diverges fails LOUD.

  The `text_matches` regex arg is the byte-sensitive landmine: the Elixir string
  `^\\[need-build\\]` must survive the YAML round-trip byte-for-byte (single-quoted
  scalar), so it is asserted explicitly on top of the whole-map equality.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Socialware.{Demo, ManifestYaml}

  # The frozen reference shape — every field of the retired
  # `reference_manifest_attrs("hello", "np")`. `bases`/`shape` are module ATOMS
  # (parse normalizes the `Elixir.`-prefixed strings via `to_existing_atom`),
  # everything else is string-keyed exactly as authored.
  @reference %{
    "name" => "hello",
    "version" => "0.1.0",
    "title" => "Pure-config hello",
    "description" => "Hello socialware authored as a manifest.",
    "uses" => ["hello"],
    "requires" => ["orchestrator"],
    "bases" => [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
    "shape" => [
      Ezagent.ActionSet.Turn,
      Ezagent.ActionSet.Surface,
      Ezagent.ActionSet.SupervisorApproval
    ],
    "views" => ["hello_render"],
    "roles" => [
      %{"role_name" => "builder", "fill" => "agent", "recipe" => "np", "flavor" => "py"},
      %{"role_name" => "responser", "fill" => "agent", "recipe" => "np", "flavor" => "py"},
      %{"role_name" => "viewer", "fill" => "human"}
    ],
    "routing_rules" => [
      %{
        "matcher" => %{"type" => "from_role", "arg" => "viewer"},
        "receivers" => ["responser"],
        "rule_set" => "default",
        "position" => 0
      },
      %{
        "matcher" => %{
          "type" => "and",
          "items" => [
            %{"type" => "from_role", "arg" => "responser"},
            %{"type" => "text_matches", "arg" => "^\\[need-build\\]"}
          ]
        },
        "receivers" => ["builder"],
        "rule_set" => "default",
        "position" => 1
      }
    ],
    "visibility_policy" => %{
      "scope" => "public",
      "publish_policy" => "supervised",
      "web_anon_access" => true
    },
    "prompt_templates" => %{},
    "legends" => %{
      "hello" => %{
        "member_set" => ["viewer", "responser", "builder"],
        "bound_rule_set" => "default",
        "fold" => false
      }
    }
  }

  test "the shipped hello manifest.yaml exists in the deploy-seed lane" do
    path = Demo.Hello.manifest_path()
    assert is_binary(path)
    assert File.exists?(path)
    assert String.ends_with?(path, "priv/socialware_seed/hello/manifest.yaml")
  end

  test "parse(YAML) is byte-for-byte the frozen reference shape (no drift)" do
    assert {:ok, parsed} = ManifestYaml.parse(File.read!(Demo.Hello.manifest_path()))
    assert parsed == @reference
  end

  test "the text_matches regex arg survives the YAML round-trip byte-for-byte" do
    {:ok, parsed} = ManifestYaml.parse(File.read!(Demo.Hello.manifest_path()))

    arg =
      parsed
      |> Map.fetch!("routing_rules")
      |> Enum.at(1)
      |> get_in(["matcher", "items"])
      |> Enum.at(1)
      |> Map.fetch!("arg")

    # The Elixir literal — a caret, a literal backslash, `[`, text, a literal
    # backslash, `]`. Anything else means the YAML scalar quoting drifted.
    assert arg == "^\\[need-build\\]"
    assert arg == "^" <> <<92>> <> "[need-build" <> <<92>> <> "]"
  end

  test "Demo.Hello.manifest_attrs/0 loads the shipped file verbatim" do
    assert Demo.Hello.manifest_attrs() == @reference
  end

  test "the :name override replaces only the name, nothing else drifts" do
    renamed = Demo.Hello.manifest_attrs(name: "hello-run-1")
    assert renamed["name"] == "hello-run-1"
    assert Map.put(renamed, "name", "hello") == @reference
  end
end
