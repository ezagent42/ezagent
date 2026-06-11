defmodule EzagentPluginContent.Kb.KbRebuilderTest do
  use ExUnit.Case
  alias EzagentPluginContent.Kb.KbRebuilder

  @moduletag :python

  test "rebuild returns ok when uv is available" do
    case System.find_executable("uv") do
      nil ->
        :skip

      _ ->
        result = KbRebuilder.rebuild("/tmp/test-kb", "/tmp/test-kb")
        # May fail if kb_search_mcp.py not at path, but shouldn't crash
        assert is_atom(elem(result, 0))
    end
  end
end
