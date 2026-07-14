defmodule EzagentWeb.HomeLiveNoAdminFallbackTest do
  use ExUnit.Case, async: true

  @home_live Path.expand("../../lib/ezagent_web/live/home_live.ex", __DIR__)

  test "invalid HomeLive identity input cannot fall back to the admin principal" do
    {:ok, ast} = @home_live |> File.read!() |> Code.string_to_quoted()

    guarded_definitions =
      ast
      |> definitions([:mount, :parse_entity_uri, :entity_principal_exists?])
      |> Enum.map_join("\n", &Macro.to_string/1)

    assert guarded_definitions =~ ":invalid_identity"
    refute guarded_definitions =~ "admin_uri"
  end

  defp definitions(ast, names) do
    {_ast, definitions} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [{name, _, _args} | _body]} = definition, acc
        when kind in [:def, :defp] ->
          if name in names do
            {definition, [definition | acc]}
          else
            {definition, acc}
          end

        node, acc ->
          {node, acc}
      end)

    definitions
  end
end
