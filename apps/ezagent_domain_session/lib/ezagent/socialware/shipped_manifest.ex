defmodule Ezagent.Socialware.ShippedManifest do
  @moduledoc """
  Shared thin loader for shipped socialware seed manifests — the deploy-seed
  packages under any loaded OTP app's `priv/socialware_seed/<pkg>/`.

  The demo test-fixture modules (`Ezagent.Socialware.Demo.Hello`,
  `EzagentPluginKanban.Demo`, …) delegate here instead of each carrying the
  same discover→read→parse→override boilerplate (the pre-#1264 cross-file
  fork this module collapses).

  NOT to be confused with `Ezagent.Socialware.ManifestSeed` — that is the boot
  scan that RESOLVES + PUBLISHES deployed manifests through the governed
  import lane. This module never publishes anything: it only discovers a
  shipped file (same `Ezagent.Home.SocialwareSeed.source_dirs/0` discovery the
  deploy-seed lane uses) and parses it via
  `Ezagent.Socialware.ManifestYaml.parse/1` into
  `ManifestResolver.resolve/1`-ready attrs (string name-refs, not modules).

  Fail-loud: `load!/2` raises on a missing or unparseable manifest — a broken
  shipped config file must never silently produce empty attrs.
  """

  alias Ezagent.Socialware.ManifestYaml

  @doc """
  Absolute path of the shipped manifest at `relpath` (e.g.
  `"kanban/manifest.yaml"`), discovered generically through
  `Ezagent.Home.SocialwareSeed.source_dirs/0` (every loaded OTP app's
  `priv/socialware_seed`) — the SAME discovery the deploy-seed lane uses.
  Names no app: whichever app ships the package is found. `nil` when no
  loaded app carries it.

  Options (tests only):
    * `:source_dirs` — override the seed source dirs (skips enumeration),
      mirroring `Ezagent.Home.SocialwareSeed.seed!/1`'s `:source` seam.
  """
  @spec path(String.t(), keyword()) :: Path.t() | nil
  def path(relpath, opts \\ []) when is_binary(relpath) do
    opts
    |> Keyword.get_lazy(:source_dirs, &Ezagent.Home.SocialwareSeed.source_dirs/0)
    |> Enum.map(&Path.join(&1, relpath))
    |> Enum.find(&File.exists?/1)
  end

  @doc """
  Load the shipped manifest at `relpath` via `ManifestYaml.parse/1` into
  `ManifestResolver.resolve/1`-ready attrs, with the demo modules' shared
  override seams applied.

  Options:
    * `:name` — override the socialware/definition name (tests pass per-run
      unique names for parallel-test isolation)
    * `:flavor` — override the flavor of EVERY agent role-slot
      (`"fill" => "agent"`; integration tests swap in a bare-spawn stub so no
      SDK sidecar starts, e2e publishes a cc variant — role names / recipes /
      routing stay the shipped ones)
    * `:source_dirs` — see `path/2` (tests only)

  Fail-loud: a missing or unparseable manifest file raises (a broken config
  file must never silently produce empty attrs).
  """
  @spec load!(String.t(), keyword()) :: map()
  def load!(relpath, opts \\ []) when is_binary(relpath) do
    opts = Keyword.validate!(opts, [:name, :flavor, :source_dirs])
    pkg = relpath |> Path.split() |> hd()

    path =
      path(relpath, Keyword.take(opts, [:source_dirs])) ||
        raise "#{pkg} manifest.yaml not found in any loaded app's priv/socialware_seed " <>
                "(expected #{relpath}); is the shipping app (ezagent_web) loaded?"

    case ManifestYaml.parse(File.read!(path)) do
      {:ok, attrs} ->
        attrs
        |> override_name(opts[:name])
        |> override_flavor(opts[:flavor])

      {:error, reason} ->
        raise "#{pkg} manifest.yaml failed to parse (#{path}): #{inspect(reason)}"
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
