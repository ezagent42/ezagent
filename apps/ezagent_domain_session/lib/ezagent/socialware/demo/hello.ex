defmodule Ezagent.Socialware.Demo.Hello do
  @moduledoc """
  Thin YAML loader + **test driver** for the hello demo socialware.

  ## Production publishes via the deploy-seed lane (NOT this module)

  The hello manifest is CONFIG — `apps/ezagent_web/priv/socialware_seed/hello/
  manifest.yaml` — carried in the release box exactly like `autoservice`. On a
  fresh stack `Ezagent.Home.SocialwareSeed` idempotently copies that package
  into the canonical deployment home (`$EZAGENT_HOME/<profile>/socialware/
  hello/`), and the late boot scan `Ezagent.Socialware.ManifestSeed.scan_all!/1`
  (run from the last-booting transport app) resolves + publishes it through the
  governed import lane. There is **zero boot-time call into this module** — the
  former `EzagentPluginHello.Application` self-publish is gone (deploy-seed SPEC
  §2/§4).

  ## What this module is for

  A test driver. `manifest_attrs/1` (no `:role_name`) loads the SAME shipped YAML
  via `Ezagent.Socialware.ManifestYaml.parse/1`, so tests exercise the exact
  manifest production ships — the file is the one source of truth and the shape
  gate (`demo_hello_test.exs`) locks it against drift. `publish/0` /
  `published?/0` walk the real governance flow so acceptance tests can drive a
  publish inside a checked-out Ecto sandbox (the boot lane skips `:test`).

  The `:role_name` option keeps the legacy single-agent fixture shape (`code`,
  not YAML) used by older materialization tests — it is a test fixture only,
  never a production shape.

  ## Where it publishes

  Into `workspace://system` (where the built-in `chat`/`socialware` definitions
  live) as a `scope: :public` definition. Public scope makes it cross-workspace
  discoverable via `DefinitionRegistry.list/1` from EVERY workspace — no
  pre-install into any workspace; users self-install through the normal
  discover→install flow.

  ## Authority

  Mirrors the operator seed ctx: `caller` = the bootstrap admin URI
  (`user://system/admin`), `caps` = the socialware `manage` cap for `hello` in
  the system workspace + `Ezagent.Capability.admin_genesis_cap/0` (the admin gate
  `publish_cr/2` requires for a `:public` scope).

  ## Idempotency

  `publish/0` routes through the shared idempotency RULE
  (`ConfigGovernance.Socialware.publish_or_upgrade/2`, P0 §5): an unchanged
  redeploy no-ops to `{:ok, :exists}` WITHOUT opening a CR; an EDITED manifest
  re-promotes to `{:ok, :upgraded}` (the old existence-check silently swallowed
  manifest edits — R-2, §5.2).
  """

  alias Ezagent.Socialware.{Definition, DefinitionRegistry, ManifestResolver, ManifestYaml}
  alias Ezagent.ConfigGovernance.Socialware, as: Governance

  @name "hello"
  @recipe "np"
  @manifest_relpath "hello/manifest.yaml"

  @doc "The stable demo socialware name (`\"hello\"`)."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The owner workspace URI string the demo publishes into (`workspace://system`)."
  @spec owner_workspace_uri() :: String.t()
  def owner_workspace_uri, do: DefinitionRegistry.system_workspace_uri()

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

  @doc """
  Publish the hello demo as a PUBLIC socialware in `workspace://system` via the
  real governance flow, through the shared idempotency RULE (P0 §5): a first
  publish is `:published`, an unchanged redeploy no-ops to `:exists` (no CR
  opened), and an EDITED manifest re-promotes to `:upgraded` (killing R-2 — the
  old existence-check silently swallowed manifest edits, §5.2/§5.3).
  """
  @spec publish() :: {:ok, :published | :upgraded | :exists} | {:error, term()}
  def publish do
    ws = Ezagent.URI.workspace(:system)
    admin = Ezagent.URI.user(:system, :admin)
    ctx = admin_ctx(admin, ws)

    with {:ok, %Definition{} = definition} <- ManifestResolver.resolve(manifest_attrs()) do
      Governance.publish_or_upgrade(definition, ctx)
    end
  end

  @doc """
  Whether the hello demo is already present as a PUBLIC definition (the
  idempotency predicate).
  """
  @spec published?() :: boolean()
  def published?, do: already_public?(Ezagent.URI.workspace(:system))

  defp admin_ctx(admin, ws) do
    %{
      caller: admin,
      workspace_uri: ws,
      caps:
        MapSet.new([
          Governance.manage_cap(@name, ws, admin),
          Ezagent.Capability.admin_genesis_cap()
        ])
    }
  end

  defp already_public?(ws) do
    case DefinitionRegistry.lookup(ws, @name) do
      {:ok, %Definition{visibility_policy: %{scope: :public}}, _object} -> true
      _ -> false
    end
  end
end
