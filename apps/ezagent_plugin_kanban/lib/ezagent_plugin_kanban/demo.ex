defmodule EzagentPluginKanban.Demo do
  @moduledoc """
  Thin YAML loader for the **kanban demo socialware** boot publish.

  #1213 landed the official config-file manifest lane
  (`Ezagent.Socialware.ManifestYaml` + the `priv/socialware/*/manifest.yaml`
  boot scan). This module's former inline `manifest_attrs/1` code map is now
  CONFIG — `priv/socialware/kanban/manifest.yaml` in THIS plugin's priv — and
  this module shrinks to the loader that publishes it at plugin boot through
  the SAME chain as `ManifestYaml.import/2`:

      parse → ManifestResolver.resolve → Conformance.check_candidate
            → ConfigGovernance.Socialware.publish_or_upgrade

  ## Why not the `ManifestSeed` boot-scan lane directly

  `Ezagent.Socialware.ManifestSeed.scan_boot_manifests!/0` only scans the
  `:ezagent_domain_session` priv dir, and it runs at domain boot — BEFORE this
  plugin's `Application.start/2` registered its plugin_info / recipes /
  `BoardView` (which `resolve` + `check_candidate` need). So the kanban
  manifest lives in the plugin's own priv and this loader runs in the plugin's
  own boot (after `Ezagent.Plugin.boot/1`). Once the deploy-seed lane is
  extended to scan plugin privs post-boot, this loader can shrink further to a
  pure path declaration.

  ## The e2e variant seam

  `manifest_attrs/1` returns the parsed YAML map with optional overrides:
  `:name` (per-run unique fixture names for parallel-test isolation) and
  `:flavor` (both agent role-slots; integration tests swap in a bare-spawn
  stub, e2e publishes a cc variant). Same YAML source → the fixtures and the
  boot demo can never drift.

  ## Idempotency / failure semantics (unchanged)

  `publish/0` routes through the shared idempotency RULE
  (`publish_or_upgrade/2`, P0 §5): `:published` → unchanged redeploy
  `:exists` (no CR) → edited manifest `:upgraded`. The boot call site
  (`EzagentPluginKanban.Application.maybe_publish_kanban_demo/0`) stays
  fail-loud in dev/prod and skipped in `:test`.
  """

  alias Ezagent.Socialware.{Conformance, Definition, DefinitionRegistry, ManifestResolver}
  alias Ezagent.ConfigGovernance.Socialware, as: Governance
  alias Ezagent.Socialware.ManifestYaml

  @name "kanban"

  # The dev-together completion marker (spec §4.2). The SINGLE contract point
  # between the routing transport and the skill protocol — this literal MUST be
  # byte-identical to the `text_contains` arg in `priv/socialware/kanban/
  # manifest.yaml` (locked by `demo_test.exs`) AND to the `__done__` marker in
  # `.claude/skills/kanban-assistant/references/kanban-team-collaboration.md` +
  # `.claude/skills/kanban-assistant/references/dev-together-relay-overlay.md`
  # (locked by `.claude/skills/kanban-assistant/scripts/relay-signal-check.sh`).
  @relay_done_marker "__done__"

  @manifest_relpath "socialware/kanban/manifest.yaml"

  @doc "The stable demo socialware name (`\"kanban\"`)."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The owner workspace URI string the demo publishes into (`workspace://system`)."
  @spec owner_workspace_uri() :: String.t()
  def owner_workspace_uri, do: DefinitionRegistry.system_workspace_uri()

  @doc "The dev-together completion marker wired into the relay-back matcher (spec §4.2 contract point)."
  @spec relay_done_marker() :: String.t()
  def relay_done_marker, do: @relay_done_marker

  @doc "Absolute path of the shipped kanban manifest YAML (this plugin's priv)."
  @spec manifest_path() :: Path.t()
  def manifest_path do
    Application.app_dir(:ezagent_plugin_kanban, "priv")
    |> Path.join(@manifest_relpath)
  end

  @doc """
  The kanban demo manifest attributes, loaded from
  `priv/socialware/kanban/manifest.yaml` via `ManifestYaml.parse/1`
  (config-authored, string name-refs, `ManifestResolver.resolve/1`-ready).

  Options (the e2e/test variant seam; both default to the shipped YAML values):
    * `:name` — override the socialware/definition name (tests pass per-run
      unique names for parallel-test isolation)
    * `:flavor` — override the flavor of EVERY agent role-slot (integration
      tests swap in a bare-spawn stub so no SDK sidecar starts; e2e publishes a
      cc variant — role names / recipes / routing stay the shipped ones)

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
        raise "kanban manifest.yaml failed to parse (#{manifest_path()}): #{inspect(reason)}"
    end
  end

  @doc """
  Publish the kanban demo as a PUBLIC socialware in `workspace://system` via
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
  Whether the kanban demo is already present as a PUBLIC definition (the
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
        %{"fill" => "agent"} = slot -> Map.put(slot, "flavor", flavor)
        slot -> slot
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
