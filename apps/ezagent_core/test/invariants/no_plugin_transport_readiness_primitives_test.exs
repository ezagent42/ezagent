defmodule Ezagent.Invariants.NoPluginTransportReadinessPrimitivesTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Gate 15: transport readiness / live-join-state primitives belong to the
  generic agent domain, not plugin apps.
  """

  @forbidden [
    ~r/defmodule\s+.*LiveJoinRegistry\b/,
    ~r/defmodule\s+.*TransportReadiness\b/,
    ~r/defmodule\s+.*ReadinessAdapter\b/
  ]

  test "plugin apps define no readiness or transport-join-state primitives" do
    umbrella_root = Path.expand("../../../..", __DIR__)

    offenders =
      Path.wildcard(Path.join(umbrella_root, "apps/ezagent_plugin_*/lib/**/*.ex"))
      |> Enum.flat_map(fn path ->
        content = File.read!(path)

        if Enum.any?(@forbidden, &Regex.match?(&1, content)) do
          [Path.relative_to(path, umbrella_root)]
        else
          []
        end
      end)

    assert offenders == [],
           """
           Readiness / transport-join-state primitives must live outside plugin apps.
           Move the primitive into apps/ezagent_domain_agent and keep plugin code to
           transport socket/channel/server calls only. Offenders:
           #{Enum.join(offenders, "\n")}
           """
  end
end
