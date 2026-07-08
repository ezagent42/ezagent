defmodule EzagentDomainInstanceMessage.SessionCreator.TemplateResolverScanTest do
  @moduledoc """
  fix/template-name-resolution — the by-scan fallback of
  `TemplateResolver.resolve_session_template!/2` must resolve the NEWEST
  version when multiple content-addressed versions of the same template
  name coexist in storage.

  Production hazard (stable DB diagnosis): when new code ships a new
  `default` SessionTemplate version, both `default@<hashA>` and
  `default@<hashB>` coexist. The old scan used `Enum.find_value` — FIRST
  MATCH, UNORDERED — over the live `KindRegistry` then snapshots, so
  `create_session("default")` could resolve the STALE version by luck.

  These tests force the scan path (a NON-`default` name has no
  `default`→`current` tag, so `find_session_template_uri` misses the tag
  and falls to the scan) and assert the newest version — ranked by the
  snapshot `inserted_at` (the version's birth time) — is always returned.
  """

  use EzagentCore.DataCase, async: false

  alias EzagentCore.Repo
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.SessionTemplate
  alias EzagentDomainInstanceMessage.SessionCreator.TemplateResolver

  @t_old ~U[2026-07-01 00:00:00.000000Z]
  @t_new ~U[2026-07-08 00:00:00.000000Z]

  # Persist a content-addressed version of `name` under `workspace_uri`.
  # `marker` varies a hashed content field (`description`) so distinct
  # markers ⇒ distinct hashes ⇒ distinct `@<hash>` versions that still
  # share the `template://<ws>/session/<name>@` prefix.
  defp persist_version(workspace_uri, name, marker) do
    content = %{
      name: name,
      description: marker,
      members: [],
      prompt_templates: %{},
      installs: [],
      legends: %{},
      routing_rules: [],
      default_workspace_uri: workspace_uri,
      parent_template_uri: nil,
      version_tag: nil,
      created_by: nil,
      created_at: nil
    }

    {:ok, %URI{} = uri} = SessionTemplate.persist_version_as_system(content, workspace_uri)
    uri
  end

  # Force the snapshot row's birth (`inserted_at`) and last-touch
  # (`updated_at`) so the two recency signals disagree — proving the fix
  # ranks by `inserted_at`, not `updated_at`.
  defp set_times(%URI{} = uri, inserted_at, updated_at) do
    row = Repo.get!(KindSnapshot, URI.to_string(uri))

    row
    |> Ecto.Changeset.change(%{inserted_at: inserted_at, updated_at: updated_at})
    |> Repo.update!()
  end

  test "scan resolves the newest version by inserted_at, not updated_at (snapshots-only)" do
    workspace_uri = Ezagent.URI.new!("workspace://scan-#{System.unique_integer([:positive])}")
    name = "scan-name-#{System.unique_integer([:positive])}"

    stale = persist_version(workspace_uri, name, "OLD-shape")
    fresh = persist_version(workspace_uri, name, "NEW-shape")

    # Reap the live Kinds so the scan reads snapshots only — this makes the
    # OLD code deterministic (its snapshot branch was `updated_at desc`),
    # so the assertion is a clean failing-first: OLD returns `stale`.
    Ezagent.Kind.terminate(stale)
    Ezagent.Kind.terminate(fresh)

    # stale is the LATER-touched (updated_at) but EARLIER-born (inserted_at);
    # fresh is the reverse. Old `updated_at desc` scan → stale. New
    # `inserted_at desc` scan → fresh.
    set_times(stale, @t_old, @t_new)
    set_times(fresh, @t_new, @t_old)

    assert {:ok, resolved_uri, _content} =
             TemplateResolver.resolve_session_template!(name, workspace_uri)

    assert URI.to_string(resolved_uri) == URI.to_string(fresh),
           "expected the newest (by inserted_at) version #{URI.to_string(fresh)}, " <>
             "got #{URI.to_string(resolved_uri)}"
  end

  test "scan resolves the newest version when BOTH versions are LIVE (production scenario)" do
    workspace_uri = Ezagent.URI.new!("workspace://scan-#{System.unique_integer([:positive])}")
    name = "scan-name-#{System.unique_integer([:positive])}"

    stale = persist_version(workspace_uri, name, "OLD-shape")
    fresh = persist_version(workspace_uri, name, "NEW-shape")

    # Both Kinds stay LIVE in the registry — the exact production hazard
    # where the unordered registry pick was luck. Rank must still come from
    # the snapshot birth time.
    set_times(stale, @t_old, @t_new)
    set_times(fresh, @t_new, @t_old)

    assert {:ok, resolved_uri, _content} =
             TemplateResolver.resolve_session_template!(name, workspace_uri)

    assert URI.to_string(resolved_uri) == URI.to_string(fresh),
           "expected the newest (by inserted_at) live version #{URI.to_string(fresh)}, " <>
             "got #{URI.to_string(resolved_uri)}"
  end
end
