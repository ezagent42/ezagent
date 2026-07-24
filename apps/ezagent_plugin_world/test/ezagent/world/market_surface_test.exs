defmodule Ezagent.World.MarketSurfaceTest do
  # PR-5 §15.5 — the socialware MARKET surface (`/market`) end-to-end through the
  # NEW UI actions (`Ezagent.World.MarketActions`), never the domain fns in
  # isolation:
  #
  #   1. browse visibility — cards come from the `DefinitionRegistry.list/1`-
  #      scoped `socialware_rows/1` (fail-before: a raw
  #      `ConfigStore.list_current_objects` scan would list the PRIVATE foreign
  #      def too);
  #   2. revision-pinned install — `market.install` pins the card's exact
  #      `{config_id, content_hash}` (a bare-name install would grab the
  #      same-named LOCAL def), and a PRIVATE foreign def's `config_id` is
  #      rejected `:socialware_revision_not_installable`;
  #   3. 上架 gate — `market.publish` on a TENANT workspace is DENIED for a
  #      genuine non-admin operator and allowed for an admin, proving the action
  #      threads the caller's REAL actor URI + REAL caps (`PresenterCaps.load/1`)
  #      into the #165 `authorize_public_scope_write` gate. Fail-before names the
  #      real bypasses: a system/service `actor_uri` (grants on
  #      `home_is_system?` caps-independently), hardcoded admin caps, or a raw
  #      `write_definition` that skips the action's cap load.
  #
  # 下架 (retract) / restore are NO LONGER World actions — the socialware manage
  # cap is not user-holdable (string subject, service-ctx only), so no World user
  # could authorize them via `PresenterCaps.load/1`. The retract gate + mechanism
  # are covered on the SERVICE path by `Ezagent.Socialware.RetractTest` (session).
  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.{Definition, DefinitionRegistry, Installation}
  alias Ezagent.World.{MarketActions, WorkspacePluginData}
  alias EzagentDomainInstanceMessage.SessionCreator.TemplateResolver

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_world)
    :ok = DefinitionRegistry.seed_builtin_definitions()
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp spawn_user(uri, opts \\ []) do
    case Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: Keyword.get(opts, :caps, [])}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  defp workspace_caps(workspace_uri, presenter) do
    Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, presenter).caps
  end


  defp socket(workspace_uri, caller, caps) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_entity_uri: caller,
        current_workspace_uri: workspace_uri,
        current_caps: caps,
        world_state: %{}
      }
    }
  end

  defp market_state(workspace_uri, caller, caps) do
    WorkspacePluginData.state_for(
      %{component: "market", title: "Market", path: "/market"},
      %{workspace_uri: workspace_uri, caller_uri: caller, caller_caps: caps}
    )
  end

  defp listed_names(state), do: Enum.map(state["socialwares"], & &1["name"])

  # Fixture seeding of catalog defs uses admin authority (a PUBLIC write is
  # #165-gated) — this is test SETUP, not the flow under test.
  defp seed_definition!(workspace_uri, name, scope, bases \\ [Ezagent.ActionSet.Session]) do
    {:ok, definition} =
      Definition.new(%{
        name: name,
        title: "Market #{name}",
        bases: bases,
        shape: [],
        visibility_policy: %{scope: scope, publish_policy: :auto, web_anon_access: false}
      })

    {:ok, object} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: workspace_uri,
        caller_workspace_uri: workspace_uri,
        actor_uri: User.admin_uri(),
        caps: MapSet.new([Capability.admin_genesis_cap()])
      )

    object
  end

  defp install_of(template_name, workspace_uri) do
    {:ok, _uri, content} =
      TemplateResolver.resolve_session_template!(template_name, workspace_uri)

    {:ok, [install]} = Installation.parsed_installs_from_template(content)
    install
  end

  test "browse lists a PUBLIC foreign def but never a PRIVATE foreign def" do
    suffix = uniq()
    ws_a = Ezagent.URI.workspace("mkt-a-#{suffix}")
    ws_b = Ezagent.URI.workspace("mkt-b-#{suffix}")
    caller_b = Ezagent.URI.user("mkt-b-#{suffix}", "operator")

    public_name = "mkt-pub-#{suffix}"
    private_name = "mkt-priv-#{suffix}"
    seed_definition!(ws_a, public_name, :public)
    seed_definition!(ws_a, private_name, :private)

    {:ok, _} = Ezagent.Workspace.create("mkt-b-#{suffix}", %{})
    :ok = spawn_user(caller_b)
    caps_b = workspace_caps(ws_b, caller_b)

    state = market_state(ws_b, caller_b, caps_b)
    names = listed_names(state)

    assert public_name in names
    refute private_name in names

    # every card carries the revision identity the revision-pinned install needs
    card = Enum.find(state["socialwares"], &(&1["name"] == public_name))
    assert is_binary(card["config_id"])
    assert is_binary(card["content_hash"])
  end

  test "install pins the card's exact config_id/content_hash; private foreign config_id rejected" do
    suffix = uniq()
    ws_a = Ezagent.URI.workspace("mkt-inst-a-#{suffix}")
    ws_b = Ezagent.URI.workspace("mkt-inst-b-#{suffix}")
    caller_b = Ezagent.URI.user("mkt-inst-b-#{suffix}", "operator")

    name = "mkt-inst-#{suffix}"
    r_pub = seed_definition!(ws_a, name, :public)
    # a SAME-NAMED local def in B — a bare-name install would grab THIS one.
    r_local = seed_definition!(ws_b, name, :private, [Ezagent.ActionSet.Publisher.SessionImpl])
    refute r_pub.id == r_local.id

    {:ok, _} = Ezagent.Workspace.create("mkt-inst-b-#{suffix}", %{})
    caps_b = workspace_caps(ws_b, caller_b)
    :ok = spawn_user(caller_b, caps: caps_b)

    {:noreply, installed} =
      MarketActions.handle_dispatch(
        socket(ws_b, caller_b, caps_b),
        "market.install",
        %{"name" => name, "config_id" => r_pub.id, "content_hash" => r_pub.content_hash}
      )

    assert installed.assigns.last_dispatch_status == "ok",
           "market install failed with #{inspect(installed.assigns)}"

    # the install template baked the EXACT foreign-public revision pin, not the
    # same-named local def.
    install = install_of("socialware-install-#{name}", ws_b)
    assert install.ref == name
    assert install.config_id == r_pub.id
    assert install.content_hash == r_pub.content_hash

    # a PRIVATE foreign def's config_id supplied directly is rejected, and no
    # install template lands in the caller's workspace.
    ws_c = Ezagent.URI.workspace("mkt-inst-c-#{suffix}")
    priv_name = "mkt-inst-priv-#{suffix}"
    r_priv = seed_definition!(ws_c, priv_name, :private)

    {:noreply, denied} =
      MarketActions.handle_dispatch(
        socket(ws_b, caller_b, caps_b),
        "market.install",
        %{"name" => priv_name, "config_id" => r_priv.id}
      )

    assert denied.assigns.last_dispatch_status =~ "socialware_revision_not_installable"

    assert {:error, _} =
             TemplateResolver.resolve_session_template!(
               "socialware-install-#{priv_name}",
               ws_b
             )

    # HARD RULE: the market install is revision-pinned — a bare-name install
    # (no config_id) is rejected outright.
    {:noreply, bare} =
      MarketActions.handle_dispatch(socket(ws_b, caller_b, caps_b), "market.install", %{
        "name" => name
      })

    assert bare.assigns.last_dispatch_status == "error:market_install_requires_revision"
  end

  test "上架 gate: non-admin publish via market action DENIED; admin ALLOWED" do
    suffix = uniq()
    ws_t = Ezagent.URI.workspace("mkt-pub-t-#{suffix}")
    ws_b = Ezagent.URI.workspace("mkt-pub-b-#{suffix}")
    operator = Ezagent.URI.user("mkt-pub-t-#{suffix}", "operator")
    name = "mkt-pub-def-#{suffix}"

    {:ok, _} = Ezagent.Workspace.create("mkt-pub-t-#{suffix}", %{})
    :ok = spawn_user(operator)
    operator_caps = workspace_caps(ws_t, operator)

    # the tenant's OWN private definition, authored by the operator themselves
    # (a private write needs no admin authority).
    {:ok, definition} =
      Definition.new(%{
        name: name,
        title: "Publish gate #{name}",
        bases: [Ezagent.ActionSet.Session],
        shape: [],
        visibility_policy: %{scope: :private, publish_policy: :auto, web_anon_access: false}
      })

    {:ok, _object} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: ws_t,
        caller_workspace_uri: ws_t,
        actor_uri: operator,
        caps: operator_caps
      )

    # NON-ADMIN publish via the NEW market action → the #165 gate DENIES, loud.
    {:noreply, denied} =
      MarketActions.handle_dispatch(socket(ws_t, operator, operator_caps), "market.publish", %{
        "name" => name
      })

    assert denied.assigns.last_dispatch_status == "error:market_publish_failed"

    assert denied.assigns.world_state["market_error"] =~ "public_socialware_requires_admin",
           "expected the #165 admin gate, got #{inspect(denied.assigns.world_state)}"

    # nothing was promoted: the def is still private and invisible from ws B.
    {:ok, still_private, _obj} = DefinitionRegistry.lookup(ws_t, name)
    assert still_private.visibility_policy.scope == :private

    refute name in listed_names(
             market_state(ws_b, Ezagent.URI.user("mkt-pub-b-#{suffix}", "v"), nil)
           )

    # ADMIN publish via the SAME action → allowed (home_is_system? admin).
    admin = User.admin_uri()
    admin_caps = workspace_caps(ws_t, admin)

    {:noreply, allowed} =
      MarketActions.handle_dispatch(socket(ws_t, admin, admin_caps), "market.publish", %{
        "name" => name
      })

    assert allowed.assigns.last_dispatch_status == "ok",
           "admin publish failed with #{inspect(allowed.assigns.world_state)}"

    {:ok, published, _obj} = DefinitionRegistry.lookup(ws_t, name)
    assert published.visibility_policy.scope == :public

    assert name in listed_names(
             market_state(ws_b, Ezagent.URI.user("mkt-pub-b-#{suffix}", "v"), nil)
           )
  end
end
