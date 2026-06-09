defmodule Ezagent.Credential.UserDefaultSourceTest do
  @moduledoc """
  #17 cascade PR-0 (codex H2) — the core store is now a pure data + read module: NO
  writer. These tests cover the PURE surface only:

    * `changeset/2` — a pure builder (no Repo write);
    * `id/3` — the deterministic primary key;
    * `resolve/3` — the read path (returns nil when unset).

  The validate-and-persist body + all four cross-source validations now live in the
  cap-checked Behavior and are exercised end-to-end through the dispatch path in
  `Ezagent.Credential.SetDefaultSourceBehaviorTest`.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Credential.UserDefaultSource, as: UDS

  @owner "entity://team-a/user/alice"
  @ws "team-a"

  test "id/3 is a deterministic key over (owner, ws, flavor)" do
    assert UDS.id(@owner, @ws, "cc") == "#{@owner}|#{@ws}|cc"
    assert UDS.id(@owner, @ws, "cc") == UDS.id(@owner, @ws, "cc")
    refute UDS.id(@owner, @ws, "cc") == UDS.id(@owner, @ws, "codex")
  end

  test "changeset/2 is a pure builder: valid attrs → valid changeset (no Repo write)" do
    src = "entity://team-a/agent/alice-base"

    cs =
      UDS.changeset(
        %{owner_uri: @owner, workspace_uri: @ws, flavor: "cc", source_uri: src},
        @owner
      )

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :id) == UDS.id(@owner, @ws, "cc")
    assert Ecto.Changeset.get_field(cs, :source_uri) == src
    assert Ecto.Changeset.get_field(cs, :set_by) == @owner

    # Pure builder: nothing was persisted.
    assert UDS.resolve(@owner, @ws, "cc") == nil
  end

  test "changeset/2 defaults set_by to owner when nil" do
    cs =
      UDS.changeset(%{
        owner_uri: @owner,
        workspace_uri: @ws,
        flavor: "cc",
        source_uri: "entity://team-a/agent/alice-base"
      })

    assert Ecto.Changeset.get_field(cs, :set_by) == @owner
  end

  test "changeset/2 with a missing source_uri is invalid (required)" do
    cs = UDS.changeset(%{owner_uri: @owner, workspace_uri: @ws, flavor: "cc"})
    refute cs.valid?
    assert %{source_uri: _} = errors_on(cs)
  end

  test "absent pointer resolves to nil (caller falls through to workspace-shared, not crash)" do
    assert UDS.resolve(@owner, @ws, "codex") == nil
  end
end
