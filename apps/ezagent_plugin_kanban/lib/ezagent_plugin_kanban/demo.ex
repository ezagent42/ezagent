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

  A test-fixture source. `manifest_attrs/1` loads the SAME shipped YAML through
  the shared `Ezagent.Socialware.ShippedManifest` loader, so tests exercise the
  exact manifest production ships — the file is the one source of truth and the
  shape gate locks it against drift.

  ## The e2e variant seam

  `manifest_attrs/1` returns the parsed YAML map with optional overrides:
  `:name` (per-run unique fixture names for parallel-test isolation) and
  `:flavor` (both agent role-slots; integration tests swap in a bare-spawn
  stub, e2e publishes a cc variant). Same YAML source → the fixtures and the
  deploy-seed publish can never drift.
  """

  alias Ezagent.Socialware.ShippedManifest

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
  Absolute path of the shipped kanban manifest YAML — see
  `Ezagent.Socialware.ShippedManifest.path/2` (generic discovery over every
  loaded OTP app's `priv/socialware_seed`; today the package ships in
  `ezagent_web`, but this names no app). `nil` when no loaded app carries the
  package.
  """
  @spec manifest_path() :: Path.t() | nil
  def manifest_path, do: ShippedManifest.path(@manifest_relpath)

  @doc """
  The kanban demo manifest attributes, loaded from the shipped
  `priv/socialware_seed/kanban/manifest.yaml` via
  `Ezagent.Socialware.ShippedManifest.load!/2` (config-authored, string
  name-refs, `ManifestResolver.resolve/1`-ready).

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
    ShippedManifest.load!(@manifest_relpath, Keyword.take(opts, [:name, :flavor]))
  end
end
