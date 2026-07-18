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
    workspace = "registration-#{System.unique_integer([:positive])}"
    {:ok, _workspace} = Ezagent.Workspace.create(workspace, %{})

    assert {:ok, uri} =
             Registration.create_principal(
               "newbie",
               "New Bie",
               "newbie@good.com",
               workspace
             )

    assert URI.to_string(uri) == "entity://#{workspace}/user/newbie"
    assert Ezagent.Users.get_by_uri(uri) != nil

    assert Profile.by_email("newbie@good.com").entity_uri ==
             "entity://#{workspace}/user/newbie"

    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(uri)
  end

  test "create_principal/4 rejects a taken slug" do
    workspace = "registration-#{System.unique_integer([:positive])}"
    {:ok, _workspace} = Ezagent.Workspace.create(workspace, %{})

    {:ok, _} =
      Registration.create_principal("dup", "Dup", "dup1@good.com", workspace)

    assert {:error, :slug_taken} =
             Registration.create_principal("dup", "Dup2", "dup2@good.com", workspace)
  end

  describe "register_with_password/4 (task #87)" do
    alias Ezagent.Entity.InviteCode
    alias Ezagent.Users

    defp mint_code(attrs \\ %{}) do
      suffix = System.unique_integer([:positive])

      base = %{
        workspace_uri: "workspace://team-alpha-#{suffix}",
        created_by: "entity://system/user/admin"
      }

      invite_attrs = Map.merge(base, attrs)
      workspace_uri = Ezagent.URI.new!(invite_attrs.workspace_uri)
      workspace_name = Ezagent.URI.name!(workspace_uri)

      if is_nil(Ezagent.Workspace.Store.get_by_name(workspace_name)) do
        {:ok, _workspace} =
          Ezagent.Workspace.create(workspace_name, %{
            created_by: Ezagent.Entity.User.admin_uri()
          })
      end

      {:ok, {raw, _row}} = InviteCode.mint(invite_attrs)
      raw
    end

    test "invite path: creates an unverified, password-set user in the code's workspace + consumes the code" do
      n = System.unique_integer([:positive])
      code = mint_code()
      email = "reg#{n}@good.com"

      assert {:ok, uri} =
               Registration.register_with_password(email, "secret123", "Reg #{n}",
                 invite_code: code
               )

      assert String.starts_with?(uri.host, "team-alpha-")
      decoded = Users.get_by_uri(uri)
      assert decoded.email_verified == false
      assert Users.verify_password(uri, "secret123")
      assert Profile.by_email(email).entity_uri == URI.to_string(uri)
      assert {:error, :exhausted} = InviteCode.validate(code)
    end

    test "invite path: an exhausted code rolls back — no user, surfaces {:invite, :exhausted}" do
      n = System.unique_integer([:positive])
      code = mint_code(%{max_uses: 1})

      {:ok, _} =
        Registration.register_with_password("a#{n}@good.com", "pw1234", "A", invite_code: code)

      assert {:error, {:invite, :exhausted}} =
               Registration.register_with_password("b#{n}@good.com", "pw1234", "B",
                 invite_code: code
               )

      # the second email never became a principal
      assert Profile.by_email("b#{n}@good.com") == nil
    end

    test "rejects a duplicate email before touching invite" do
      n = System.unique_integer([:positive])
      email = "taken#{n}@good.com"

      {:ok, _} =
        Profile.upsert(%{
          entity_uri: "entity://team-alpha/user/pre#{n}",
          display_name: "Pre",
          email: email
        })

      assert {:error, :email_taken} =
               Registration.register_with_password(email, "pw1234", "X", invite_code: mint_code())
    end

    test "open self-serve creates one owned workspace and concrete signed founder caps" do
      n = System.unique_integer([:positive])
      email = "founder#{n}@good.com"

      assert {:ok, uri} =
               Registration.register_with_password(email, "pw1234", "Founder",
                 mode: :open_self_serve
               )

      workspace_uri = Ezagent.URI.entity_workspace_uri(uri)
      workspace_name = Ezagent.URI.name!(workspace_uri)
      workspace = Ezagent.Workspace.Store.get_by_name(workspace_name)

      assert workspace.created_by == uri
      assert Enum.any?(workspace.members, &(URI.to_string(&1) == URI.to_string(uri)))

      held = Ezagent.Identity.list_caps_for(uri)

      assert Enum.any?(held, fn cap ->
               cap.behavior == Ezagent.ActionSet.WorkspaceUserAdmin and
                 cap.action == :mint_invite and cap.instance == workspace_uri and
                 is_binary(cap.signature)
             end)

      refute Enum.any?(held, &match?({:within_workspace, _}, &1.instance))
    end

    test "no target → :no_registration_target" do
      n = System.unique_integer([:positive])

      assert {:error, :no_registration_target} =
               Registration.register_with_password("nt#{n}@good.com", "pw1234", "NT", [])
    end
  end
end
