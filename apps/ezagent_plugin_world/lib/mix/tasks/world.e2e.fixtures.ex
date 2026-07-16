defmodule Mix.Tasks.World.E2e.Fixtures do
  @moduledoc """
  Generate or verify the checked-in frontend Tier-1 fixture projection.

      mix world.e2e.fixtures
      mix world.e2e.fixtures --check
  """
  use Mix.Task

  @builtin_uri_schemes ~w(entity workspace session template resource system)

  @shortdoc "Regenerate (or --check) World Tier-1 browser fixtures"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {opts, _, _} = OptionParser.parse(args, switches: [check: :boolean])
    path = fixture_path()
    ensure_builtin_uri_schemes!()
    generated = Ezagent.World.E2EFixtures.manifest_json()

    if opts[:check] do
      on_disk = if File.exists?(path), do: File.read!(path), else: ""

      if on_disk == generated do
        Mix.shell().info("world E2E fixtures in sync (#{relative(path)})")
      else
        Mix.raise(
          "world E2E fixtures are stale — run `mix world.e2e.fixtures` and commit #{relative(path)}"
        )
      end
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, generated)
      Mix.shell().info("wrote #{relative(path)}")
    end
  end

  defp fixture_path do
    cond do
      File.dir?("apps/ezagent_plugin_world/assets") ->
        "apps/ezagent_plugin_world/assets/e2e/fixtures/world.e2e.fixtures.json"

      File.dir?("assets") ->
        "assets/e2e/fixtures/world.e2e.fixtures.json"

      true ->
        Mix.raise("cannot locate world assets — run from the umbrella root or the plugin app")
    end
  end

  # `app.config` intentionally avoids booting the DB-backed umbrella. The
  # projection still uses canonical Ezagent.URI builders, so seed the same
  # built-in schemes that EzagentCore.Application installs during normal boot.
  defp ensure_builtin_uri_schemes! do
    :ok = Ezagent.URI.SchemeRegistry.init()

    Enum.each(@builtin_uri_schemes, fn scheme ->
      :ok = Ezagent.URI.SchemeRegistry.register(scheme)
    end)
  end

  defp relative(path), do: Path.relative_to_cwd(path)
end
