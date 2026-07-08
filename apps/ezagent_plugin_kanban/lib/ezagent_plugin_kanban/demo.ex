defmodule EzagentPluginKanban.Demo do
  @moduledoc """
  Thin YAML loader + **test fixture source** for the kanban demo socialware.

  ## Production publishes via the deploy-seed lane (NOT this module)

  The kanban manifest is CONFIG — `apps/ezagent_web/priv/socialware_seed/kanban/
  manifest.yaml` — carried in the release box exactly like `autoservice` /
  `hello`. On a fresh stack `Ezagent.Home.SocialwareSeed` idempotently copies
  that package into the canonical deployment home
  (`$EZAGENT_HOME/<profile>/socialware/kanban/`) and the late boot scan
  (`Ezagent.Socialware.ManifestSeed.scan_all!/1`, run from the last-booting
  transport app AFTER the kanban plugin registered its plugin_info + `BoardView`
  so `uses: ["kanban"]` + the `kanban_render` view resolve) publishes it through
  the governed import lane. There is **zero self-publish** in this module — the
  former `EzagentPluginKanban.Application` boot publish AND the old
  `Demo.publish/0` primitive are both gone (deploy-seed SPEC §2/§4).

  ## What this module is for

  A test-fixture source. `manifest_attrs/1` loads the SAME shipped YAML via
  `Ezagent.Socialware.ManifestYaml.parse/1`, so tests exercise the exact
  manifest production ships — the file is the one source of truth and the shape
  gate locks it against drift.

  ## The e2e variant seam

  `manifest_attrs/1` returns the parsed YAML map with optional overrides:
  `:name` (per-run unique fixture names for parallel-test isolation) and
  `:flavor` (both agent role-slots; integration tests swap in a bare-spawn
  stub, e2e publishes a cc variant). Same YAML source → the fixtures and the
  deploy-seed publish can never drift.
  """

  alias Ezagent.Socialware.ManifestYaml

  @name "kanban"

  # The dev-together completion marker (spec §4.2). The SINGLE contract point
  # between the routing transport and the skill protocol — this literal MUST be
  # byte-identical to the `text_contains` arg in
  # `apps/ezagent_web/priv/socialware_seed/kanban/manifest.yaml` (locked by
  # `demo_test.exs`) AND to the `__done__` marker in
  # `.claude/skills/kanban-assistant/references/kanban-team-collaboration.md` +
  # `.claude/skills/kanban-assistant/references/dev-together-relay-overlay.md`
  # (locked by `.claude/skills/kanban-assistant/scripts/relay-signal-check.sh`).
  @relay_done_marker "__done__"

  @manifest_relpath "kanban/manifest.yaml"

  @doc "The stable demo socialware name (`\"kanban\"`)."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The dev-together completion marker wired into the relay-back matcher (spec §4.2 contract point)."
  @spec relay_done_marker() :: String.t()
  def relay_done_marker, do: @relay_done_marker

  @doc """
  Absolute path of the shipped kanban manifest YAML, discovered generically
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
  The kanban demo manifest attributes, loaded from the shipped
  `priv/socialware_seed/kanban/manifest.yaml` via `ManifestYaml.parse/1`
  (config-authored, string name-refs, `ManifestResolver.resolve/1`-ready).

  Options (the e2e/test variant seam; both default to the shipped YAML values):
    * `:name` — override the socialware/definition name (tests pass per-run
      unique names for parallel-test isolation)
    * `:flavor` — override the flavor of EVERY agent role-slot (integration
      tests swap in a bare-spawn stub so no SDK sidecar starts; e2e publishes a
      cc variant — role names / recipes / routing stay the shipped ones)

  Fail-loud: a missing or unparseable manifest file raises (a broken config file
  must never silently produce empty attrs).
  """
  @spec manifest_attrs(keyword()) :: map()
  def manifest_attrs(opts \\ []) do
    path =
      manifest_path() ||
        raise "kanban manifest.yaml not found in any loaded app's priv/socialware_seed " <>
                "(expected #{@manifest_relpath}); is the shipping app (ezagent_web) loaded?"

    case ManifestYaml.parse(File.read!(path)) do
      {:ok, attrs} ->
        attrs
        |> override_name(Keyword.get(opts, :name))
        |> override_flavor(Keyword.get(opts, :flavor))

      {:error, reason} ->
        raise "kanban manifest.yaml failed to parse (#{path}): #{inspect(reason)}"
    end
  end

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
end
