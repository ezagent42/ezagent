defmodule EzagentPluginCrawler.Demo do
  @moduledoc """
  Thin YAML loader + **test fixture source** for the dealscout demo socialware.

  ## Production publishes via the deploy-seed lane (NOT this module)

  The dealscout manifest is CONFIG — `apps/ezagent_web/priv/socialware_seed/
  dealscout/manifest.yaml` — carried in the release box exactly like
  `autoservice` / `hello` / `kanban`. On a fresh stack
  `Ezagent.Home.SocialwareSeed` idempotently copies that package into the
  canonical deployment home (`$EZAGENT_HOME/<profile>/socialware/dealscout/`)
  and the late boot scan (`Ezagent.Socialware.ManifestSeed.scan_all!/1`, run
  from the last-booting transport app AFTER the crawler plugin + hello
  registered their plugin_info + `PageView` so `uses: ["hello", "crawler"]` +
  the `hello_render` view resolve) publishes it through the governed import
  lane. There is **zero self-publish** in this module — the former
  `EzagentPluginCrawler.Application` boot publish AND the old `Demo.publish/0`
  primitive are both gone (deploy-seed SPEC §2/§4).

  ## What this module is for

  A test-fixture source. `manifest_attrs/1` loads the SAME shipped YAML via
  `Ezagent.Socialware.ManifestYaml.parse/1`, so tests exercise the exact
  manifest production ships — the file is the one source of truth and the shape
  gate locks it against drift.

  ## The e2e variant seam

  `manifest_attrs/1` returns the parsed YAML map with optional overrides:
  `:name` (per-run unique fixture names for parallel-test isolation) and
  `:flavor` (the `discover` agent role-slot ONLY — integration tests swap in a
  bare-spawn stub so no cc SDK sidecar starts; unlike kanban, where BOTH slots
  swap, the `page` slot stays pinned `dealscout-page-alt × native`, the
  explicit temporary ALT that flips back to `hello.builder` once A①/#1201 ③
  lands). Same YAML source → the fixtures and the deploy-seed publish can never
  drift.
  """

  alias Ezagent.Socialware.ManifestYaml

  @name "dealscout"
  # discover 角色槽名（`:flavor` override 只换这一槽——page 槽是临时 ALT ×
  # native 的页面刷新腿，不随 stub 换）。
  @discover_role "discover"

  @manifest_relpath "dealscout/manifest.yaml"

  @doc "The stable demo socialware name (`\"dealscout\"`)."
  @spec name() :: String.t()
  def name, do: @name

  @doc """
  Absolute path of the shipped dealscout manifest YAML, discovered generically
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
  The dealscout demo manifest attributes, loaded from the shipped
  `priv/socialware_seed/dealscout/manifest.yaml` via `ManifestYaml.parse/1`
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

  Fail-loud: a missing or unparseable manifest file raises (a broken config file
  must never silently produce empty attrs).
  """
  @spec manifest_attrs(keyword()) :: map()
  def manifest_attrs(opts \\ []) do
    path =
      manifest_path() ||
        raise "dealscout manifest.yaml not found in any loaded app's priv/socialware_seed " <>
                "(expected #{@manifest_relpath}); is the shipping app (ezagent_web) loaded?"

    case ManifestYaml.parse(File.read!(path)) do
      {:ok, attrs} ->
        attrs
        |> override_name(Keyword.get(opts, :name))
        |> override_flavor(Keyword.get(opts, :flavor))

      {:error, reason} ->
        raise "dealscout manifest.yaml failed to parse (#{path}): #{inspect(reason)}"
    end
  end

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
end
