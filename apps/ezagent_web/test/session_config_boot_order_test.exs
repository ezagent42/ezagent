defmodule EzagentWeb.SessionConfigBootOrderTest do
  use ExUnit.Case, async: true

  test "Session-Config extensions freeze before the HTTP endpoint starts" do
    source =
      File.read!(Path.expand("../lib/ezagent_web/application.ex", __DIR__))

    assemble_at = source_index!(source, "ExtensionRegistry.assemble!(")
    endpoint_start_at = source_index!(source, "Supervisor.start_link(children, opts)")

    assert assemble_at < endpoint_start_at
  end

  defp source_index!(source, needle) do
    case :binary.match(source, needle) do
      {index, _length} -> index
      :nomatch -> flunk("missing source marker: #{needle}")
    end
  end
end
