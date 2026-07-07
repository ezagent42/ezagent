defmodule EzagentPluginCrawler.Demo do
  @moduledoc """
  Thin YAML loader for the **dealscout demo socialware** boot publish.

  #1213 landed the official config-file manifest lane
  (`Ezagent.Socialware.ManifestYaml` + the `priv/socialware/*/manifest.yaml`
  boot scan). This module's former inline `manifest_attrs/1` code map is now
  CONFIG — `priv/socialware/dealscout/manifest.yaml` in THIS plugin's priv
  (see the file's header for what dealscout composes: hello 公开面 + crawler
  爬取后台 + 临时 ALT page 槽 + update-signal routing) — and this module
  shrinks to the loader that publishes it at plugin boot through the SAME
  chain as `ManifestYaml.import/2`:

      parse → ManifestResolver.resolve → Conformance.check_candidate
            → ConfigGovernance.Socialware.publish_or_upgrade

  ## Why not the `ManifestSeed` boot-scan lane directly

  `Ezagent.Socialware.ManifestSeed.scan_boot_manifests!/0` only scans the
  `:ezagent_domain_session` priv dir, and it runs at domain boot — BEFORE this
  plugin's `Application.start/2` registered its plugin_info / recipes (and
  before hello registered its `PageView`, which `resolve` + `check_candidate`
  need for `hello_render`). So the dealscout manifest lives in the plugin's
  own priv and this loader runs in the plugin's own boot (after
  `Ezagent.Plugin.boot/1`). Once the deploy-seed lane is extended to scan
  plugin privs post-boot, this loader can shrink further to a pure path
  declaration.

  ## The e2e variant seam

  `manifest_attrs/1` returns the parsed YAML map with optional overrides:
  `:name` (per-run unique fixture names for parallel-test isolation) and
  `:flavor` (the `discover` agent role-slot ONLY — integration tests swap in a
  bare-spawn stub so no cc SDK sidecar starts; unlike kanban, where BOTH slots
  swap, the `page` slot stays pinned `dealscout-page-alt × native`, the
  explicit temporary ALT that flips back to `hello.builder` once A①/#1201 ③
  lands). Same YAML source → the fixtures and the boot demo can never drift.

  ## Idempotency / failure semantics (unchanged)

  `publish/0` routes through the shared idempotency RULE
  (`publish_or_upgrade/2`, P0 §5): `:published` → unchanged redeploy
  `:exists` (no CR) → edited manifest `:upgraded`. The boot call site
  (`EzagentPluginCrawler.Application.maybe_publish_dealscout_demo/0`) stays
  fail-loud in dev/prod and skipped in `:test`.
  """

  alias Ezagent.ConfigGovernance.Socialware, as: Governance
  alias Ezagent.Socialware.{Conformance, Definition, DefinitionRegistry, ManifestResolver}
  alias Ezagent.Socialware.ManifestYaml

  @name "dealscout"
  # discover 角色槽名（`:flavor` override 只换这一槽——page 槽是临时 ALT ×
  # native 的页面刷新腿，不随 stub 换）。
  @discover_role "discover"

  @manifest_relpath "socialware/dealscout/manifest.yaml"

  @doc "The stable demo socialware name (`\"dealscout\"`)."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The owner workspace URI string the demo publishes into (`workspace://system`)."
  @spec owner_workspace_uri() :: String.t()
  def owner_workspace_uri, do: DefinitionRegistry.system_workspace_uri()

  @doc "Absolute path of the shipped dealscout manifest YAML (this plugin's priv)."
  @spec manifest_path() :: Path.t()
  def manifest_path do
    Application.app_dir(:ezagent_plugin_crawler, "priv")
    |> Path.join(@manifest_relpath)
  end

  @doc """
  The dealscout demo manifest attributes, loaded from
  `priv/socialware/dealscout/manifest.yaml` via `ManifestYaml.parse/1`
  (config-authored, string name-refs, `ManifestResolver.resolve/1`-ready).

  Options (the e2e/test variant seam; both default to the shipped YAML values):
    * `:name` — override the socialware/definition name (tests pass per-run
      unique names for parallel-test isolation)
    * `:flavor` — override the flavor of the `discover` agent role-slot ONLY
      (integration tests swap in a bare-spawn stub so no cc SDK sidecar
      starts). The `page` slot is NOT swapped — it is pinned
      `dealscout-page-alt × native`（临时 ALT，A① 落地后回切 `hello.builder`，
      moduledoc §The e2e variant seam）(unlike kanban, where BOTH slots are
      cc-headless and both swap).

  Fail-loud: a missing or unparseable manifest file raises (the boot publish
  must never silently proceed on a broken config file).
  """
  @spec manifest_attrs(keyword()) :: map()
  def manifest_attrs(opts \\ []) do
    yaml = File.read!(manifest_path())

    case ManifestYaml.parse(yaml) do
      {:ok, attrs} ->
        attrs
        |> override_name(Keyword.get(opts, :name))
        |> override_flavor(Keyword.get(opts, :flavor))

      {:error, reason} ->
        raise "dealscout manifest.yaml failed to parse (#{manifest_path()}): #{inspect(reason)}"
    end
  end

  @doc """
  Publish the dealscout demo as a PUBLIC socialware in `workspace://system` via
  the real governance flow, walking the SAME chain as `ManifestYaml.import/2`
  (resolve → check_candidate → publish_or_upgrade) through the shared
  idempotency RULE (P0 §5): first publish `:published`, unchanged redeploy
  `:exists` (no CR opened), edited manifest `:upgraded`.
  """
  @spec publish() :: {:ok, :published | :upgraded | :exists} | {:error, term()}
  def publish do
    ws = Ezagent.URI.workspace(:system)
    admin = Ezagent.URI.user(:system, :admin)
    ctx = admin_ctx(admin, ws)

    with {:ok, %Definition{} = definition} <- ManifestResolver.resolve(manifest_attrs()),
         :ok <- Conformance.check_candidate(definition, ws) do
      Governance.publish_or_upgrade(definition, ctx)
    end
  end

  @doc """
  Whether the dealscout demo is already present as a PUBLIC definition (the
  idempotency predicate).
  """
  @spec published?() :: boolean()
  def published?, do: already_public?(Ezagent.URI.workspace(:system))

  defp override_name(attrs, nil), do: attrs
  defp override_name(attrs, name) when is_binary(name), do: Map.put(attrs, "name", name)

  defp override_flavor(attrs, nil), do: attrs

  defp override_flavor(attrs, flavor) when is_binary(flavor) do
    Map.update!(attrs, "roles", fn roles ->
      Enum.map(roles, fn
        %{"fill" => "agent", "role_name" => @discover_role} = slot ->
          Map.put(slot, "flavor", flavor)

        slot ->
          slot
      end)
    end)
  end

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
