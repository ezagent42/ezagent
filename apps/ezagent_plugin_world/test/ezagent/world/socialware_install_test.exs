defmodule Ezagent.World.SocialwareInstallTest do
  # P1 §O-1 — the catalog install entry point (`session.create` →
  # `prepare_create_template`) must thread the def's revision identity
  # (`config_id` + `content_hash`) so it installs the EXACT revision the user saw,
  # scope-gated in `DefinitionRegistry.resolve_installable_revision/3`. These tests
  # drive the REAL entry point (not just the predicate) so a green predicate can
  # never mask an entry point that forgot to call it.
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{Definition, DefinitionRegistry, Installation}
  alias Ezagent.World.SocialwareInstall
  alias EzagentDomainInstanceMessage.SessionCreator.TemplateResolver

  @caller Ezagent.URI.new!("entity://cidw-consumer/user/operator")
  @author Ezagent.URI.new!("entity://cidw-pub/user/author")
  @ws_consumer Ezagent.URI.new!("workspace://cidw-consumer")
  @ws_pub Ezagent.URI.new!("workspace://cidw-pub")
  @ws_priv Ezagent.URI.new!("workspace://cidw-priv")

  defp uniq, do: System.unique_integer([:positive])

  # `SessionTemplate.create` grants an owner cap to the caller's User Kind, so the
  # caller must be a live actor (else `:no_such_actor`). Spawn it once per test.
  defp spawn_caller! do
    case Ezagent.Kind.spawn(Ezagent.Entity.User, %{
           uri: @caller,
           initial_caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
         }) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  defp write!(name, bases, workspace_uri, scope) do
    {:ok, definition} =
      Definition.new(%{
        name: name,
        title: "CIDW #{name}",
        bases: bases,
        shape: [],
        visibility_policy: %{scope: scope, publish_policy: :auto, web_anon_access: false}
      })

    {:ok, object} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: workspace_uri,
        caller_workspace_uri: workspace_uri,
        actor_uri: @author,
        # #165: seeding a public catalog def now requires admin authority.
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
      )

    object
  end

  defp install_of(template_name, workspace_uri) do
    {:ok, _uri, content} =
      TemplateResolver.resolve_session_template!(template_name, workspace_uri)

    {:ok, [install]} = Installation.parsed_installs_from_template(content)
    install
  end

  test "install-by-config_id bakes the EXACT foreign-public revision pin (not a same-named local)" do
    spawn_caller!()
    name = "cidw-#{uniq()}"
    r_pub = write!(name, [Ezagent.ActionSet.Session], @ws_pub, :public)
    r_local = write!(name, [Ezagent.ActionSet.Publisher.SessionImpl], @ws_consumer, :private)
    refute r_pub.id == r_local.id

    assert {:ok, template_name} =
             SocialwareInstall.prepare_create_template(@ws_consumer, @caller, "default", name, %{
               config_id: r_pub.id,
               content_hash: r_pub.content_hash
             })

    install = install_of(template_name, @ws_consumer)
    assert install.ref == name
    # pinned to the foreign public revision, NOT the same-named local one.
    assert install.config_id == r_pub.id
    assert install.content_hash == r_pub.content_hash
  end

  test "SECURITY: install-by-config_id of a PRIVATE foreign def is rejected + writes NO install template" do
    name = "cidw-priv-#{uniq()}"
    r_priv = write!(name, [Ezagent.ActionSet.Session], @ws_priv, :private)

    assert {:error, {:socialware_revision_not_installable, ^name}} =
             SocialwareInstall.prepare_create_template(@ws_consumer, @caller, "default", name, %{
               config_id: r_priv.id
             })

    # the entry point errored BEFORE persisting — no install template landed in
    # the caller's workspace.
    assert {:error, _} =
             TemplateResolver.resolve_session_template!(
               "socialware-install-#{name}",
               @ws_consumer
             )
  end

  test "backward-compat: name-only install writes a bare-name (unpinned) install template" do
    spawn_caller!()
    name = "cidw-name-#{uniq()}"
    write!(name, [Ezagent.ActionSet.Session], @ws_pub, :public)

    assert {:ok, template_name} =
             SocialwareInstall.prepare_create_template(
               @ws_consumer,
               @caller,
               "default",
               name,
               nil
             )

    install = install_of(template_name, @ws_consumer)
    assert install.ref == name
    assert install.config_id == nil
  end

  test "operator role-slot choices are carried only as install config" do
    spawn_caller!()
    name = "cidw-role-slots-#{uniq()}"
    write!(name, [Ezagent.ActionSet.Session], @ws_pub, :public)

    role_slots = [
      %{"role_name" => "researcher", "mode" => "fresh", "flavor" => "codex"},
      %{
        "role_name" => "advisor",
        "mode" => "reuse",
        "agent_uri" => "entity://cidw-consumer/agent/alice-advisor"
      }
    ]

    assert {:ok, template_name} =
             SocialwareInstall.prepare_create_template(
               @ws_consumer,
               @caller,
               "default",
               name,
               nil,
               %{"role_slots" => role_slots}
             )

    install = install_of(template_name, @ws_consumer)
    assert install.ref == name
    assert install.config == %{"role_slots" => role_slots}
  end
end
