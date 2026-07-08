defmodule Ezagent.Socialware.Demo.Hello do
  @moduledoc """
  Thin YAML loader + **test fixture source** for the hello demo socialware.

  ## Production AND tests publish via the deploy-seed lane (NOT this module)

  The hello manifest is CONFIG — `apps/ezagent_web/priv/socialware_seed/hello/
  manifest.yaml` — carried in the release box exactly like `autoservice`. On a
  fresh stack `Ezagent.Home.SocialwareSeed` idempotently copies that package
  into the canonical deployment home (`$EZAGENT_HOME/<profile>/socialware/
  hello/`), and the manifest scan (`Ezagent.Socialware.ManifestSeed.scan_dir!/1`,
  or `scan_all!/1` at boot from the last-booting transport app) resolves +
  publishes it through the governed import lane. There is **zero self-publish**
  in this module — the former `EzagentPluginHello.Application` boot publish AND
  the old `Demo.Hello.publish/0` primitive are both gone (deploy-seed SPEC
  §2/§4). The acceptance test (#162) seeds a temp deploy dir and scans it,
  exercising the exact production lane.

  ## What this module is for

  A test-fixture source. `manifest_attrs/1` (no `:role_name`) loads the SAME
  shipped YAML via `Ezagent.Socialware.ManifestYaml.parse/1`, so tests exercise
  the exact manifest production ships — the file is the one source of truth and
  the shape gate (`demo_hello_test.exs`) locks it against drift.

  The `:role_name` option keeps the legacy single-agent fixture shape (`code`,
  not YAML) used by older materialization tests — it is a test fixture only,
  never a production shape.
  """

  alias Ezagent.Socialware.ManifestYaml

  @name "hello"
  @recipe "np"
  @manifest_relpath "hello/manifest.yaml"

  @doc "The stable demo socialware name (`\"hello\"`)."
  @spec name() :: String.t()
  def name, do: @name

  @doc """
  Absolute path of the shipped hello manifest YAML, discovered generically
  through `Ezagent.Home.SocialwareSeed.source_dirs/0` (every loaded OTP app's
  `priv/socialware_seed`) — the SAME discovery the deploy-seed lane uses. Today
  the package ships in `ezagent_web`, but this names no app: whichever app ships
  it is found. `nil` when no loaded app carries the package.
  """
  @spec manifest_path() :: Path.t() | nil
  def manifest_path do
    Ezagent.Home.SocialwareSeed.source_dirs()
    |> Enum.map(&Path.join(&1, @manifest_relpath))
    |> Enum.find(&File.exists?/1)
  end

  @doc """
  The hello demo manifest attributes.

  With NO `:role_name`, the reference (3-role) shape is loaded from the shipped
  `manifest.yaml` via `ManifestYaml.parse/1` — the file production ships is the
  one source of truth. Fail-loud: a missing or unparseable manifest raises.

  Options:
    * `:name` — override the socialware/definition name (tests pass per-run
      unique names for parallel-test isolation; default `"hello"`)
    * `:recipe_name` — the agent recipe (legacy branch only; default `"np"`)
    * `:role_name` — when present, emit the legacy single-agent fixture shape
      (`code`, not YAML) used by older materialization tests.

  The returned map is `ManifestResolver.resolve/1`-ready (name refs, not modules).
  """
  @spec manifest_attrs(keyword()) :: map()
  def manifest_attrs(opts \\ []) do
    if Keyword.has_key?(opts, :role_name) do
      name = Keyword.get(opts, :name, @name)
      recipe_name = Keyword.get(opts, :recipe_name, @recipe)
      legacy_manifest_attrs(name, recipe_name, Keyword.fetch!(opts, :role_name))
    else
      reference_manifest_attrs(Keyword.get(opts, :name, @name))
    end
  end

  # Load the shipped reference manifest from YAML and apply the `:name` override.
  defp reference_manifest_attrs(name) do
    path =
      manifest_path() ||
        raise "hello manifest.yaml not found in any loaded app's priv/socialware_seed " <>
                "(expected #{@manifest_relpath}); is the shipping app (ezagent_web) loaded?"

    case ManifestYaml.parse(File.read!(path)) do
      {:ok, attrs} ->
        Map.put(attrs, "name", name)

      {:error, reason} ->
        raise "hello manifest.yaml failed to parse (#{path}): #{inspect(reason)}"
    end
  end

  defp base_manifest_attrs(name) do
    %{
      "name" => name,
      "version" => "0.1.0",
      "title" => "Pure-config hello",
      "description" => "Hello socialware authored as a manifest.",
      "uses" => ["hello"],
      "requires" => ["orchestrator"],
      "bases" => [
        "Elixir.Ezagent.ActionSet.Session",
        "Elixir.Ezagent.ActionSet.Publisher.SessionImpl"
      ],
      "shape" => [
        "Elixir.Ezagent.ActionSet.Turn",
        "Elixir.Ezagent.ActionSet.Surface",
        "Elixir.Ezagent.ActionSet.SupervisorApproval"
      ],
      "views" => ["hello_render"],
      "visibility_policy" => %{
        "scope" => "public",
        "publish_policy" => "supervised",
        "web_anon_access" => true
      }
    }
  end

  defp legacy_manifest_attrs(name, recipe_name, role_name) do
    base_manifest_attrs(name)
    |> Map.merge(%{
      "roles" => [
        %{"role_name" => role_name, "fill" => "agent", "recipe" => recipe_name, "flavor" => "py"}
      ],
      "prompt_templates" => %{"hello" => "Say hello: {body}"},
      "legends" => %{
        "hello" => %{
          "member_set" => [role_name],
          "bound_rule_set" => "default",
          "fold" => false
        }
      },
      "routing_rules" => [
        %{
          "matcher" => %{"type" => "always"},
          "receivers" => [role_name],
          "rule_set" => "default",
          "position" => 0,
          "prompt_template_ref" => "hello"
        }
      ]
    })
  end
end
