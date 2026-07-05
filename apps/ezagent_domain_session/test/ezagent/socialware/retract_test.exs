defmodule Ezagent.Socialware.RetractTest do
  # SPEC §6 / §8.3 — def-level RETRACT: a SEPARATE catalog-state marker (NOT a
  # field in the def body, so artifact identity survives a retract/restore cycle)
  # that filters the def out of `DefinitionRegistry.list/1` (the discoverable
  # catalog) and the `lookup/2` PUBLIC fallback (so a NEW install cannot select
  # it). An EXISTING pinned install is GRANDFATHERED (§9 coupling) because
  # freeze-pin (§4) baked the pinned `config_id` into the session's local template
  # content — behavior-set resolution reads the frozen revision via
  # `fetch_object/1`, never re-running the name-`lookup` retract makes fail.
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.ConfigGovernance.Socialware, as: Governance
  alias Ezagent.Socialware.{Definition, DefinitionRegistry, Installation}

  @owner Ezagent.URI.new!("entity://team-ret/user/owner")
  @actor Ezagent.URI.new!("entity://team-ret/user/owner")
  @ws_a Ezagent.URI.new!("workspace://team-ret")
  @ws_b Ezagent.URI.new!("workspace://team-ret-consumer")

  defp uniq, do: System.unique_integer([:positive])

  defp attrs(name, bases, scope) do
    %{
      name: name,
      title: "Retract #{name}",
      bases: bases,
      shape: [],
      visibility_policy: %{scope: scope, publish_policy: :auto, web_anon_access: false}
    }
  end

  # Fast setup: a resolvable revision in workspace A (public so a consumer
  # workspace B can discover/install it). The RETRACT itself always goes through
  # the real admin-gated governance path.
  defp write!(name, bases, workspace_uri \\ @ws_a, scope \\ :public) do
    {:ok, definition} = Definition.new(attrs(name, bases, scope))

    {:ok, object} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: workspace_uri,
        caller_workspace_uri: workspace_uri,
        actor_uri: @actor,
        # #165: seeding a public catalog def now requires admin authority.
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
      )

    object
  end

  defp admin_ctx(name) do
    %{
      caller: @owner,
      workspace_uri: @ws_a,
      caps:
        MapSet.new([
          Governance.manage_cap(name, @ws_a, @owner),
          Ezagent.Capability.admin_genesis_cap()
        ])
    }
  end

  test "T-Ret-a: retract hides a def from list/1 and the public lookup/2 fallback" do
    name = "ret-a-#{uniq()}"
    write!(name, [Ezagent.ActionSet.Session])

    # discoverable + installable from a CONSUMER workspace BEFORE retract
    assert Enum.any?(DefinitionRegistry.list(@ws_b), &(&1.name == name and &1.public?))
    assert {:ok, _def, _obj} = DefinitionRegistry.lookup(@ws_b, name)

    assert {:ok, %{retracted: true}} = Governance.retract(name, admin_ctx(name))

    # gone from the consumer catalog
    refute Enum.any?(DefinitionRegistry.list(@ws_b), &(&1.name == name))
    # the public fallback no longer resolves → a fresh install cannot select it
    assert :error = DefinitionRegistry.lookup(@ws_b, name)

    assert {:error, {:unknown_socialware_install, ^name}} =
             Installation.freeze_template_installs(%{installs: [name]}, @ws_b)
  end

  test "T-Ret-b: a grandfathered pinned install still resolves + rebuilds after retract (§9)" do
    name = "ret-b-#{uniq()}"
    session_uri = Ezagent.URI.session("team-ret-consumer", "generic", name)
    r1 = write!(name, [Ezagent.ActionSet.Session])

    # consumer B installs while the def is LIVE — freeze pins R1's config_id into
    # the content, and the per-session install record is written pinned to R1.
    {:ok, frozen} = Installation.freeze_template_installs(%{installs: [name]}, @ws_b)
    :ok = Installation.install_template_installs(session_uri, @ws_b, frozen, @actor)

    assert {:ok, %{retracted: true}} = Governance.retract(name, admin_ctx(name))

    # GRANDFATHER 1 — the pinned install record still resolves the exact revision
    # (via fetch_object(config_id), unaffected by the catalog marker).
    assert [%Definition{} = installed] = Installation.installed_definitions(session_uri)
    assert installed.name == name

    # GRANDFATHER 2 — the frozen content still rebuilds its behavior set from R1,
    # because behavior-set resolution reads the frozen config_id (bypasses lookup).
    {:ok, [{_d, obj, _i}]} = Installation.resolved_template_installs(frozen, @ws_b)
    assert obj.id == r1.id
    assert {:ok, behaviors} = Installation.behavior_set_for_template(frozen, @ws_b)
    assert Ezagent.ActionSet.Session in behaviors

    # CONTROL (§9 coupling) — an UNPINNED live resolution now FAILS: the def is
    # gone from the catalog. The grandfather holds ONLY because the pin was frozen.
    assert {:error, {:unknown_socialware_install, ^name}} =
             Installation.behavior_set_for_template(%{installs: [name]}, @ws_b)
  end

  test "T-Ret-d: retract blocks a NEW install by ref even in the def's OWNING workspace" do
    name = "ret-d-#{uniq()}"
    r1 = write!(name, [Ezagent.ActionSet.Session])

    # BEFORE retract: the owning workspace resolves + can freshly install by ref.
    assert {:ok, _def, obj} = DefinitionRegistry.lookup(@ws_a, name)
    assert obj.id == r1.id

    # A grandfathered install pinned WHILE LIVE — its record carries R1's config_id.
    session_uri = Ezagent.URI.session("team-ret", "generic", name)
    {:ok, frozen} = Installation.freeze_template_installs(%{installs: [name]}, @ws_a)
    :ok = Installation.install_template_installs(session_uri, @ws_a, frozen, @actor)

    assert {:ok, %{retracted: true}} = Governance.retract(name, admin_ctx(name))

    # AFTER retract: the OWNING-workspace lookup no longer resolves it, so a fresh
    # install-by-ref (freeze → lookup) is rejected — "no NEW install can select it"
    # now holds in the def's own workspace, not just for consumers (T-Ret-a).
    assert :error = DefinitionRegistry.lookup(@ws_a, name)

    assert {:error, {:unknown_socialware_install, ^name}} =
             Installation.freeze_template_installs(%{installs: [name]}, @ws_a)

    # GRANDFATHER — the EXISTING pinned install still resolves its frozen revision
    # (via fetch_object(config_id), which never re-runs the retract-aware lookup).
    assert [%Definition{} = installed] = Installation.installed_definitions(session_uri)
    assert installed.name == name
  end

  test "T-Ret-c: restore reverses retract; revision id + content-hash preserved" do
    name = "ret-c-#{uniq()}"
    r1 = write!(name, [Ezagent.ActionSet.Session])
    {:ok, _d, before_obj} = DefinitionRegistry.lookup(@ws_b, name)

    assert {:ok, %{retracted: true}} = Governance.retract(name, admin_ctx(name))
    assert :error = DefinitionRegistry.lookup(@ws_b, name)

    assert {:ok, %{retracted: false}} = Governance.restore(name, admin_ctx(name))

    # back in the catalog + installable again
    assert Enum.any?(DefinitionRegistry.list(@ws_b), &(&1.name == name))
    assert {:ok, _d2, after_obj} = DefinitionRegistry.lookup(@ws_b, name)

    # SAME revision + SAME content-hash — the marker is SEPARATE from the def body,
    # so retract/restore never mutated the artifact's identity (D-4 payoff).
    assert after_obj.id == before_obj.id
    assert after_obj.id == r1.id
    assert after_obj.content_hash == before_obj.content_hash
  end

  test "retract is scoped to the def's workspace — a same-named def elsewhere is unaffected" do
    name = "ret-x-#{uniq()}"
    ws_c = Ezagent.URI.new!("workspace://team-ret-other")

    # public def owned by workspace A + a DIFFERENT workspace C's OWN private def
    # of the SAME name.
    write!(name, [Ezagent.ActionSet.Session])
    write!(name, [Ezagent.ActionSet.Session], ws_c, :private)

    assert {:ok, %{retracted: true}} = Governance.retract(name, admin_ctx(name))

    # C's OWN def still resolves for C (caller-workspace branch — the (name, A)
    # marker must not hide the (name, C) object).
    assert {:ok, cdef, _obj} = DefinitionRegistry.lookup(ws_c, name)
    assert cdef.name == name
    assert Enum.any?(DefinitionRegistry.list(ws_c), &(&1.name == name))
  end

  test "retract requires admin (public-scope gate)" do
    name = "ret-noadmin-#{uniq()}"
    write!(name, [Ezagent.ActionSet.Session])

    non_admin = %{
      caller: @owner,
      workspace_uri: @ws_a,
      caps: MapSet.new([Governance.manage_cap(name, @ws_a, @owner)])
    }

    assert {:error, :public_socialware_requires_admin} = Governance.retract(name, non_admin)
  end
end
