defmodule Ezagent.Socialware.PublicViewSplitGateTest do
  use ExUnit.Case, async: true

  @moduledoc """
  P4 gate: production code must not read or write the retired SessionTemplate
  `public_view` boolean.
  """

  @forbidden [
    {~r/PublicView\.public_view\?/, "old anonymous-access gate"},
    {~r/\bpublic_view:\s*/, "atom-key template flag"},
    {~r/"public_view"\s*=>/, "string-key template flag"}
  ]

  test "production code uses install relation and web_anon_access instead of public_view" do
    violations =
      production_files()
      |> Enum.flat_map(fn path ->
        text = File.read!(path)

        @forbidden
        |> Enum.flat_map(fn {regex, label} ->
          case Regex.run(regex, text, return: :index) do
            nil -> []
            [{offset, _}] -> ["#{path}: #{label} at byte #{offset}"]
          end
        end)
      end)

    assert violations == []
  end

  defp production_files do
    [
      "apps/*/lib/**/*.{ex,exs}",
      "apps/*/assets/**/*.{ts,tsx,js}",
      "apps/*/priv/static/**/*.html",
      "scripts/**/*.{ex,exs}"
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.reject(&String.contains?(&1, "/test/"))
  end
end
