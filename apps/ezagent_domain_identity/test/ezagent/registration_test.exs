defmodule Ezagent.RegistrationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Registration
  alias Ezagent.Entity.Profile

  # SPEC v2 PR-F (2026-05-24) — the `default` workspace was deleted in
  # PR-C (#295), so these tests now pass an explicit `"default"`
  # workspace string as a test fixture name (it lives only as a string
  # in slug-uniqueness lookups + entity URI construction; it is not
  # backed by a real Workspace row in this test). Tests that need an
  # actual Workspace row create one explicitly per setup.
  @test_workspace "default"

  test "derive_slug/1 lowercases and sanitizes the email local part" do
    assert Registration.derive_slug("Allen.Woods@example.com") == "allen-woods"
    assert Registration.derive_slug("a+tag@example.com") == "a-tag"
  end

  test "slug_available?/2 + suggest_slug/2" do
    assert Registration.slug_available?("freshslug", @test_workspace)

    {:ok, _} =
      Ezagent.Users.create("entity://#{@test_workspace}/user/taken", nil, [])

    refute Registration.slug_available?("taken", @test_workspace)
    assert Registration.suggest_slug("taken", @test_workspace) == "taken-2"
  end

  # `Registration.domain_allowed?/1` was DELETED in SPEC v2 PR-G2
  # (2026-05-24). Per-workspace `magic_link_rule` rows are the sole
  # gate; tests should use `Registration.email_allowed?/1` which
  # consults the new path.
  test "email_allowed?/1 returns true when a workspace's rule accepts the email" do
    _ = Ezagent.Workspace.create("rg-test-#{System.unique_integer([:positive])}", %{})
    [ws | _] = Ezagent.Workspace.list_all() |> Enum.reverse()
    _ = Ezagent.Workspace.add_magic_link_rule(ws.uri, "domain", "good.com")

    assert Registration.email_allowed?("x@good.com")
    refute Registration.email_allowed?("x@nowhere.test")
  end

  test "principal_for_email/1 resolves an existing profile" do
    {:ok, _} =
      Profile.upsert(%{
        entity_uri: "entity://#{@test_workspace}/user/known",
        display_name: "Known",
        email: "known@good.com"
      })

    # Compare via the canonical constructor `Ezagent.URI.new!/1` — the
    # same one `principal_for_email/1` uses. Stdlib `URI.parse/1` would
    # populate the deprecated `:authority` field that `Ezagent.URI`
    # deliberately omits, producing a spurious struct mismatch.
    assert Registration.principal_for_email("known@good.com") ==
             {:ok, Ezagent.URI.new!("entity://#{@test_workspace}/user/known")}

    assert Registration.principal_for_email("nobody@good.com") == :none
  end

  test "create_principal/4 creates user + profile + spawns the Kind" do
    assert {:ok, uri} =
             Registration.create_principal(
               "newbie",
               "New Bie",
               "newbie@good.com",
               @test_workspace
             )

    assert URI.to_string(uri) == "entity://#{@test_workspace}/user/newbie"
    assert Ezagent.Users.get_by_uri(uri) != nil

    assert Profile.by_email("newbie@good.com").entity_uri ==
             "entity://#{@test_workspace}/user/newbie"

    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(uri)
  end

  test "create_principal/4 rejects a taken slug" do
    {:ok, _} =
      Registration.create_principal("dup", "Dup", "dup1@good.com", @test_workspace)

    assert {:error, :slug_taken} =
             Registration.create_principal("dup", "Dup2", "dup2@good.com", @test_workspace)
  end
end
