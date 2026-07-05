Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.SocialwareDeclarationUriGateTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Gate A (socialware role-slot P1): a socialware declaration must not be able to
  name a participant instance URI.

  Scope: this is a static source gate over repo-authored socialware Definition,
  conformance, editor, and role-slot materialization code, plus a recursive
  decoded-map scanner for persisted JSON-like bodies. It intentionally excludes
  legacy SessionTemplate `members` compatibility in `TemplateTeam`: that path
  can still lazily provision old template declarations, but it is not a
  socialware Definition authoring or persistence surface.
  """

  @repo_root Path.expand("../../../..", __DIR__)

  @scanned_files [
    "apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex",
    "apps/ezagent_domain_session/lib/ezagent/socialware/conformance.ex",
    "apps/ezagent_domain_session/lib/ezagent/socialware/definition_editor.ex",
    "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex",
    "apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex"
  ]

  @participant_uri ~r/^entity:\/\/[^\/]+\/(agent|user)\//

  @forbidden_source_patterns [
    {:definition_members_field, ~r/\bmembers:\s*\[\]/},
    {:definition_agents_field, ~r/\bagents:\s*\[\]/},
    {:definition_body_members, ~r/\bmembers:\s*json_safe\(/},
    {:definition_body_agents, ~r/\bagents:\s*json_safe\(/},
    {:direct_member_uri_clause, ~r/member_uri_field\(member,\s*:uri\)/},
    {:source_template_uri_declaration,
     ~r/member_uri_field\(declaration,\s*:source_template_uri\)/},
    {:uri_receiver_allowed, ~r/receiver_resolvable\?\(%URI\{\}/},
    {:receiver_uri_parse_allowed, ~r/Ezagent\.URI\.parse\(r\)/},
    {:template_members_declaration,
     ~r/Map\.get\(content,\s*:members\)\s*\|\|\s*Map\.get\(content,\s*"members"\)/}
  ]

  test "no participant instance URI can be declared in socialware definition/render code" do
    offenders =
      @scanned_files
      |> Enum.flat_map(&scan_file/1)

    assert offenders == [],
           """
           Socialware declaration/render code still has a participant-instance declaration
           surface. P1 requires role slots only: %{role_name, fill: :agent, recipe, flavor}
           or %{role_name, fill: :human}. Remove members/direct uri/source_template_uri
           declaration paths and URI receivers from socialware-authored definitions.

           Offenders:
           #{format(offenders)}
           """
  end

  test "decoded-map scanner catches participant instance URIs in role/member/receiver positions" do
    planted = %{
      "roles" => [
        %{"role_name" => "ok", "fill" => "human"},
        %{"role_name" => "bad", "uri" => "entity://acme/agent/stolen"}
      ],
      "members" => [
        %{"role_name" => "visitor", "uri" => "entity://acme/user/alice"}
      ],
      "routing_rules" => [
        %{"receivers" => ["bot", "entity://acme/agent/credentialed"]}
      ],
      "owner_policy" => %{"type" => "installer"}
    }

    assert Enum.sort(decoded_body_offenders(planted)) ==
             Enum.sort([
               {:roles, ["roles", 1, "uri"], "entity://acme/agent/stolen"},
               {:members, ["members", 0, "uri"], "entity://acme/user/alice"},
               {:receivers, ["routing_rules", 0, "receivers", 1],
                "entity://acme/agent/credentialed"}
             ])
  end

  defp scan_file(rel) do
    source =
      @repo_root
      |> Path.join(rel)
      |> File.read!()

    @forbidden_source_patterns
    |> Enum.flat_map(fn {reason, pattern} ->
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _line_no} -> line =~ pattern end)
      |> Enum.map(fn {_line, line_no} -> {rel, line_no, reason} end)
    end)
  end

  defp decoded_body_offenders(body) do
    body
    |> scan_decoded([])
    |> Enum.reverse()
  end

  defp scan_decoded(%{} = map, path) do
    Enum.flat_map(map, fn {key, value} ->
      scan_decoded(value, path ++ [key])
    end)
  end

  defp scan_decoded(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> scan_decoded(value, path ++ [index]) end)
  end

  defp scan_decoded(value, path) when is_binary(value) do
    if participant_uri?(value) and declaration_position?(path) do
      [{position_kind(path), path, value}]
    else
      []
    end
  end

  defp scan_decoded(_value, _path), do: []

  defp participant_uri?(value), do: value =~ @participant_uri

  defp declaration_position?(path),
    do: Enum.any?(path, &(&1 in ["roles", "members", "receivers"]))

  defp position_kind(path) do
    cond do
      "roles" in path -> :roles
      "members" in path -> :members
      "receivers" in path -> :receivers
    end
  end

  defp format([]), do: "  (none)"

  defp format(offenders) do
    offenders
    |> Enum.map(fn {rel, line, reason} -> "  #{rel}:#{line} #{reason}" end)
    |> Enum.join("\n")
  end
end
