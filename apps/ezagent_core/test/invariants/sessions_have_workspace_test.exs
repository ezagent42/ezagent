defmodule EzagentCore.Invariants.SessionsHaveWorkspaceTest do
  @moduledoc """
  Phase 8c PR-E (Allen 2026-05-20) — architectural invariant test.
  Phase 9 PR-7 (SPEC v3 §3.6) — extended to assert URI-shape
  conformance.

  Every live session in `Ezagent.KindRegistry` must:

  1. Carry its workspace structurally in its URI (3-segment shape
     `session://<template>/<workspace>/<name>`) — PR-7 source of
     truth.
  2. If also bound in `Ezagent.WorkspaceRegistry`, the binding MUST
     equal the workspace segment of the URI (the cache must agree
     with the URI; divergent state is a structural bug).

  The strict pre-PR-7 requirement that every session ALSO have a
  registry binding was relaxed — PR-7 makes the registry a
  consistency cache rather than the authoritative source.

  ## How to fix a failing test

  If you add a new session whose URI is 2-segment, fix the URI
  construction site to follow the 3-segment shape. If a registered
  session has a divergent registry binding, the bug is whichever
  code wrote the divergent binding (search call sites of
  `Ezagent.WorkspaceRegistry.bind/2`).
  """
  use ExUnit.Case, async: false

  alias Ezagent.{Capability, KindRegistry, WorkspaceRegistry}

  test "every session URI in KindRegistry is 3-segment (SPEC v3 §3.6 PR-7)" do
    sessions =
      KindRegistry.list_all()
      |> Enum.filter(fn entry ->
        uri = entry_uri(entry)
        uri != nil and URI.parse(uri).scheme == "session"
      end)

    bad_shape =
      sessions
      |> Enum.reject(fn entry ->
        uri_str = entry_uri(entry)

        try do
          parsed = Ezagent.URI.new!(uri_str)
          ws = Capability.workspace_of(parsed)
          match?(%URI{scheme: "workspace"}, ws)
        rescue
          _ -> false
        end
      end)
      |> Enum.map(&entry_uri/1)

    assert bad_shape == [],
           """
           Sessions with non-3-segment URI (SPEC v3 §3.6 violated):
           #{Enum.map_join(bad_shape, "\n  ", &"- #{&1}")}

           Every session URI must be `session://<template>/<workspace>/<name>`.
           Construction sites: `Ezagent.Workspace.create_session/3`,
           `Ezagent.Entity.Session.spawn_from_template/2`,
           `Ezagent.Template.GenericSession.instantiate/3`.
           """
  end

  test "WorkspaceRegistry bindings agree with URI workspace segment (PR-7)" do
    sessions =
      KindRegistry.list_all()
      |> Enum.filter(fn entry ->
        uri = entry_uri(entry)
        uri != nil and URI.parse(uri).scheme == "session"
      end)

    divergent =
      sessions
      |> Enum.flat_map(fn entry ->
        uri_str = entry_uri(entry)
        parsed = URI.parse(uri_str)

        case WorkspaceRegistry.lookup(uri_str) do
          {:ok, bound_ws} ->
            structural_ws =
              try do
                Capability.workspace_of(parsed)
              rescue
                _ -> nil
              end

            if match?(%URI{}, structural_ws) and
                 URI.to_string(structural_ws) != URI.to_string(bound_ws) do
              [{uri_str, URI.to_string(bound_ws), URI.to_string(structural_ws)}]
            else
              []
            end

          :error ->
            []
        end
      end)

    assert divergent == [],
           """
           WorkspaceRegistry bindings diverge from URI workspace segment:
           #{Enum.map_join(divergent, "\n  ", fn {uri, bound, structural} -> "- #{uri}\n    registry: #{bound}\n    URI path: #{structural}" end)}

           PR-7 makes WorkspaceRegistry a consistency cache; every
           binding must equal the workspace segment of its bound URI.
           """
  end

  # KindRegistry entries are tuples — extract URI string regardless of shape.
  defp entry_uri({uri, _kind_module, _pid}) when is_binary(uri), do: uri
  defp entry_uri({uri, _kind_module}) when is_binary(uri), do: uri
  defp entry_uri(%{uri: uri}) when is_binary(uri), do: uri
  defp entry_uri(uri) when is_binary(uri), do: uri
  defp entry_uri(_), do: nil
end
