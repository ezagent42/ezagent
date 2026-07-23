defmodule Ezagent.ProviderConnection.EffectBoundaryWrappingTest do
  @moduledoc """
  Structural gate: every driver/credential-backend effect call in the
  provider-connection domain must be wrapped in `EffectBoundary.invoke/2` so a
  plugin raise/throw/exit carrying provider bodies or credential material can
  never reach Kind runtime logs or caller-visible error tuples (design §14,
  handoff §5). Inline try/rescue effect wrappers are forbidden so the boundary
  has exactly one implementation; the two remaining `rescue` blocks in the
  local authorization backend belong to AEAD unseal authentication (local
  crypto, not plugin calls) and are pinned as the only permitted occurrences.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @files %{
    "lib/ezagent/provider_connection/credential_refresh_exchange.ex" => 3,
    "lib/ezagent/provider_connection/refresh.ex" => 4,
    "lib/ezagent/provider_connection/termination.ex" => 2,
    "lib/ezagent/provider_connection/credential_replacement.ex" => 3,
    "lib/ezagent/provider_connection/recovery.ex" => 1,
    "lib/ezagent/provider_connection/local_authorization_backend/exchange.ex" => 3,
    "lib/ezagent/provider_connection/local_authorization_backend/reconciliation.ex" => 1
  }

  @crypto_rescue_allowlist %{
    "lib/ezagent/provider_connection/local_authorization_backend/exchange.ex" => 1,
    "lib/ezagent/provider_connection/local_authorization_backend/reconciliation.ex" => 1
  }

  for {file, expected} <- @files do
    test "#{file} routes exactly #{expected} effect calls through EffectBoundary" do
      source = File.read!(Path.join(@root, unquote(file)))

      assert length(Regex.scan(~r/EffectBoundary\.invoke\(/, source)) == unquote(expected),
             "#{unquote(file)} must wrap every effect call in EffectBoundary.invoke/2"
    end
  end

  for file <- Map.keys(@files) do
    test "#{file} has no inline try/rescue effect wrapper left" do
      source = File.read!(Path.join(@root, unquote(file)))

      refute Regex.match?(~r/try do\s*\n\s*apply\(/, source),
             "#{unquote(file)} still wraps an apply/3 effect call inline"

      allowed = Map.get(@crypto_rescue_allowlist, unquote(file), 0)
      rescues = length(Regex.scan(~r/^\s*rescue$/m, source))

      assert rescues == allowed,
             "#{unquote(file)} has #{rescues} rescue blocks; only #{allowed} AEAD unseal rescue(s) permitted"
    end
  end

  test "no bare driver/backend effect apply remains outside EffectBoundary" do
    for file <- Map.keys(@files) do
      lines =
        file |> then(fn path -> File.read!(Path.join(@root, path)) end) |> String.split("\n")

      {_inside?, violations} =
        Enum.reduce(lines, {false, []}, fn line, {inside?, violations} ->
          cond do
            line =~ ~r/EffectBoundary\.invoke\(/ ->
              {true, violations}

            inside? and line =~ ~r/^\s*(end[,\)]?|\))\s*$/ ->
              {false, violations}

            not inside? and line =~ ~r/^\s*(\w+ = )?apply\(/ ->
              {inside?, [String.trim(line) | violations]}

            true ->
              {inside?, violations}
          end
        end)

      assert violations == [],
             "#{file} contains bare apply outside EffectBoundary.invoke: #{inspect(violations)}"
    end
  end

  test "closed codes used at the boundary are exactly the per-site established vocabulary" do
    expectations = %{
      "lib/ezagent/provider_connection/credential_refresh_exchange.ex" => [
        ":provider_protocol_failed",
        ":authorization_backend_unavailable"
      ],
      "lib/ezagent/provider_connection/refresh.ex" => [
        ":authorization_backend_unavailable",
        ":backend_unavailable"
      ],
      "lib/ezagent/provider_connection/termination.ex" => [":backend_unavailable"],
      "lib/ezagent/provider_connection/credential_replacement.ex" => [
        ":authorization_backend_unavailable",
        ":backend_unavailable"
      ],
      "lib/ezagent/provider_connection/recovery.ex" => [":recovery_failed"],
      "lib/ezagent/provider_connection/local_authorization_backend/exchange.ex" => [
        ":provider_protocol_error",
        ":authorization_backend_unavailable"
      ],
      "lib/ezagent/provider_connection/local_authorization_backend/reconciliation.ex" => [
        ":provider_protocol_error"
      ]
    }

    for {file, codes} <- expectations do
      source = File.read!(Path.join(@root, file))

      used =
        Regex.scan(~r/EffectBoundary\.invoke\(\s*\n(?:.|\n)*?,\s*:([a-z_]+)\s*\n?\s*\)/, source)
        |> List.flatten()
        |> Enum.uniq()

      for code <- codes do
        assert String.trim_leading(code, ":") in used,
               "#{file} must normalize its effect calls to #{code}; got #{inspect(used)}"
      end
    end
  end
end
