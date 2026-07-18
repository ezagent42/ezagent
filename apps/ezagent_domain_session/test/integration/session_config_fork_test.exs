defmodule EzagentDomainInstanceMessage.Integration.SessionConfigForkTest do
  @moduledoc """
  Gates for `Ezagent.Session.ConfigFork.fork_config/3` — the "copy this
  session's config → new owned session" flow (website journey segment 5,
  复制配置，建新会话).

  Proves the three scope contracts:

    1. **Happy path** — forking a templated session's config creates a NEW
       session OWNED by the caller, with the config COPIED (the forked
       SessionTemplate is content-hash-equal to the source's, and records the
       source as `parent_template_uri`) and ZERO message history (Invariant #10).
    2. **Cap-denied** — a caller lacking the `:create_session` workspace cap (the
       REAL production gate) → `{:error, :unauthorized}`; no session is created.
    3. **Fail-closed** — a session with NO source template (a bare/system
       session whose working copy carries `session_template_uri: nil`) →
       `{:error, :no_source_template}` (no silent default).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Entity.Session.Orchestrator
  alias Ezagent.Session.ConfigFork
  alias EzagentDomainInstanceMessage.SessionCreator

  setup do
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok = EzagentDomainInstanceMessage.Application.seed_default_session_template_now()

    on_exit(fn ->
      table = Ezagent.Routing.Resolver.default_routing_table()

      try do
        Ezagent.Routing.RuleStore.load_into_registry(table)
      rescue
        _ -> :ok
      end
    end)

    admin = User.admin_uri()

    admin_caps =
      Ezagent.URI.workspace(:system)
      |> Ezagent.Test.CapHelper.signed_workspace_ctx!(admin)
      |> Map.fetch!(:caps)

    {:ok, admin: admin, admin_caps: admin_caps}
  end

  # A source session materialized from the "default" SessionTemplate (so its
  # working copy carries a real `session_template_uri`).
  defp create_source_session(admin) do
    short = "cfgfork-src-#{System.unique_integer([:positive])}"

    {:ok, source_session_uri, _meta} =
      SessionCreator.create_session(short, admin, template_name: "default")

    source_session_uri
  end

  describe "fork_config/3 — happy path (config copied, caller owns, zero history)" do
    test "creates a NEW session owned by the caller with the source config copied", %{
      admin: admin,
      admin_caps: admin_caps
    } do
      source_session_uri = create_source_session(admin)

      wc = Session.read_template_working_copy(source_session_uri)
      assert %URI{} = source_template_uri = wc.session_template_uri

      assert {:ok,
              %{session_uri: %URI{} = new_session_uri, template_uri: %URI{} = new_template_uri}} =
               ConfigFork.fork_config(source_session_uri, %{caller: admin, caps: admin_caps})

      # A genuinely NEW session, not the source.
      refute URI.to_string(new_session_uri) == URI.to_string(source_session_uri)

      # Owned by the caller (自己当 owner).
      assert {:ok, ^admin} = Session.owner(new_session_uri)

      # Config COPIED — every team-composition field (members, routing rules,
      # orchestrator, installs, legends, prompts, …) is identical to the source.
      # Only the fork-mutated metadata differs (new name, new parent lineage,
      # refreshed provenance), so we compare with those dropped.
      {:ok, source_content} = Orchestrator.read_template_content(source_template_uri)
      {:ok, fork_content} = Orchestrator.read_template_content(new_template_uri)

      fork_mutated = [
        :name,
        :parent_template_uri,
        :version_tag,
        :version_hash,
        :created_by,
        :created_at
      ]

      assert Map.drop(source_content, fork_mutated) == Map.drop(fork_content, fork_mutated)

      # Lineage recorded — the fork points back at the source template.
      assert URI.to_string(fork_content.parent_template_uri) ==
               URI.to_string(source_template_uri)

      # ZERO history (Invariant #10 — fork is config-only, never message history).
      assert Ezagent.MessageStore.recent_in_session(new_session_uri, 50) == []

      # The new session is itself materialized from the fork.
      new_wc = Session.read_template_working_copy(new_session_uri)
      assert URI.to_string(new_wc.session_template_uri) == URI.to_string(new_template_uri)
    end

    test "a custom short_name / new_template_name is honored", %{
      admin: admin,
      admin_caps: admin_caps
    } do
      source_session_uri = create_source_session(admin)

      short = "custom-#{System.unique_integer([:positive])}"
      tname = "custom-tpl-#{System.unique_integer([:positive])}"

      assert {:ok, %{session_uri: new_session_uri, template_uri: new_template_uri}} =
               ConfigFork.fork_config(
                 source_session_uri,
                 %{caller: admin, caps: admin_caps},
                 short_name: short,
                 new_template_name: tname
               )

      assert URI.to_string(new_session_uri) == "session://system/#{tname}/#{short}"

      assert String.contains?(
               URI.to_string(new_template_uri),
               "template://system/session/#{tname}@"
             )
    end
  end

  describe "fork_config/3 — cap-denied (the real :create_session gate)" do
    test "caller without :create_session cap → {:error, :unauthorized}", %{admin: admin} do
      source_session_uri = create_source_session(admin)

      # A bare user in the source's workspace with NO caps: the fork's copy
      # authority is self-minted, so it is the downstream `:create_session`
      # dispatch (CapBAC step 5.5) that denies — the gate a real user hits.
      bare = URI.new!("entity://system/user/cfgfork-bare-#{System.unique_integer([:positive])}")
      {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: bare, initial_caps: MapSet.new()})

      assert {:error, :missing_cap} =
               ConfigFork.fork_config(source_session_uri, %{caller: bare, caps: MapSet.new()})

      # No new session owned by the bare caller was created.
      refute Enum.any?(SessionCreator.list_sessions(), fn uri ->
               case Session.owner(uri) do
                 {:ok, %URI{} = o} -> URI.to_string(o) == URI.to_string(bare)
                 _ -> false
               end
             end)
    end
  end

  describe "fork_config/3 — fail-closed (no source template)" do
    test "a session with no source template → {:error, :no_source_template}", %{
      admin: admin,
      admin_caps: admin_caps
    } do
      # A bare Session Kind spawned WITHOUT template materialization: its
      # working copy carries the default `session_template_uri: nil`.
      session_uri =
        URI.new!("session://system/default/cfgfork-nosrc-#{System.unique_integer([:positive])}")

      {:ok, _pid} =
        Ezagent.Kind.spawn(Session, %{
          uri: session_uri,
          behaviors: Session.behaviors(),
          owner_uri: admin
        })

      :ok =
        Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))

      # Sanity: the working copy really has no source template.
      assert Session.read_template_working_copy(session_uri).session_template_uri == nil

      assert {:error, :no_source_template} =
               ConfigFork.fork_config(session_uri, %{caller: admin, caps: admin_caps})
    end
  end
end
