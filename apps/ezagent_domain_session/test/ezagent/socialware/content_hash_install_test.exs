defmodule Ezagent.Socialware.ContentHashInstallTest do
  # P1 §O-1 — content-hash-addressed install. The catalog is cross-workspace, but
  # bare-name `lookup/2` resolves caller-workspace-first, so clicking a foreign
  # PUBLIC card and installing could silently install a SAME-NAMED LOCAL def. The
  # fix: install by the def's EXACT revision identity (`config_id`, the immutable
  # `ConfigObject.id`; `content_hash` is the env-stable identity the UI shows),
  # resolved through the scope-gated `DefinitionRegistry.resolve_installable_revision/3`.
  #
  # SECURITY: `fetch_object/1` alone would return ANY revision by id, including a
  # PRIVATE foreign-workspace one — so the resolver MUST re-apply the same
  # installable-scope gate as `list/1`/`lookup/2` (own-workspace OR system OR
  # public, and NOT retracted). These tests prove the gate + the exact-revision
  # pin thread it through the existing freeze-pin machinery.
  use EzagentCore.DataCase, async: false

  alias Ezagent.ConfigGovernance.Socialware, as: Governance
  alias Ezagent.Socialware.{Definition, DefinitionRegistry, Installation}

  @actor Ezagent.URI.new!("entity://cid-pub/user/author")
  @owner Ezagent.URI.new!("entity://cid-pub/user/author")
  @ws_pub Ezagent.URI.new!("workspace://cid-pub")
  @ws_consumer Ezagent.URI.new!("workspace://cid-consumer")
  @ws_priv Ezagent.URI.new!("workspace://cid-priv")

  defp uniq, do: System.unique_integer([:positive])

  defp attrs(name, bases, scope) do
    %{
      name: name,
      title: "CID #{name}",
      bases: bases,
      shape: [],
      visibility_policy: %{scope: scope, publish_policy: :auto, web_anon_access: false}
    }
  end

  defp write!(name, bases, workspace_uri, scope) do
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
      workspace_uri: @ws_pub,
      caps:
        MapSet.new([
          Governance.manage_cap(name, @ws_pub, @owner),
          Ezagent.Capability.admin_genesis_cap()
        ])
    }
  end

  test "T-CID-1: install-by-config_id resolves the EXACT foreign PUBLIC revision, not a same-named local def" do
    name = "cid1-#{uniq()}"
    # foreign PUBLIC def in ws_pub + a SAME-NAMED PRIVATE local def in the consumer
    # workspace with DIFFERENT bases.
    r_pub = write!(name, [Ezagent.ActionSet.Session], @ws_pub, :public)
    r_local = write!(name, [Ezagent.ActionSet.Publisher.SessionImpl], @ws_consumer, :private)
    refute r_pub.id == r_local.id

    # The O-1 hazard is real: bare-name lookup from the consumer prefers the LOCAL def.
    assert {:ok, _ldef, lobj} = DefinitionRegistry.lookup(@ws_consumer, name)
    assert lobj.id == r_local.id

    # Content-hash-addressed install resolves the EXACT foreign public revision.
    assert {:ok, %Definition{name: ^name}, obj} =
             DefinitionRegistry.resolve_installable_revision(@ws_consumer, r_pub.id)

    assert obj.id == r_pub.id

    # And the pin threads through freeze-pin: the frozen content resolves r_pub.
    content = %{installs: [%{ref: name, config_id: r_pub.id, content_hash: r_pub.content_hash}]}
    assert {:ok, frozen} = Installation.freeze_template_installs(content, @ws_consumer)
    assert {:ok, [{_d, fobj, _i}]} = Installation.resolved_template_installs(frozen, @ws_consumer)
    assert fobj.id == r_pub.id
  end

  test "T-CID-2 (SECURITY): install-by-config_id of a PRIVATE foreign-workspace def is REJECTED" do
    name = "cid2-#{uniq()}"
    r_priv = write!(name, [Ezagent.ActionSet.Session], @ws_priv, :private)

    # A consumer workspace must NOT be able to install a PRIVATE foreign revision
    # by supplying its config_id — the scope gate rejects it.
    assert {:error, {:socialware_revision_not_installable, ^name}} =
             DefinitionRegistry.resolve_installable_revision(@ws_consumer, r_priv.id)

    # CONTROL: the OWNING workspace CAN install its own private revision.
    assert {:ok, %Definition{name: ^name}, obj} =
             DefinitionRegistry.resolve_installable_revision(@ws_priv, r_priv.id)

    assert obj.id == r_priv.id
  end

  test "T-CID-3: install-by-config_id of a RETRACTED def is rejected" do
    name = "cid3-#{uniq()}"
    r = write!(name, [Ezagent.ActionSet.Session], @ws_pub, :public)

    # installable while live
    assert {:ok, _d, _o} = DefinitionRegistry.resolve_installable_revision(@ws_consumer, r.id)

    assert {:ok, %{retracted: true}} = Governance.retract(name, admin_ctx(name))

    # after retract the revision is non-installable (consistent with the P0 retract
    # fix: a retracted def is non-installable even by its exact config_id).
    assert {:error, {:socialware_revision_retracted, ^name}} =
             DefinitionRegistry.resolve_installable_revision(@ws_consumer, r.id)
  end

  test "T-CID-4: a content_hash mismatch (pointer/UI drift) is rejected; the matching hash resolves" do
    name = "cid4-#{uniq()}"
    r = write!(name, [Ezagent.ActionSet.Session], @ws_pub, :public)

    # matching content_hash → ok
    assert {:ok, _d, obj} =
             DefinitionRegistry.resolve_installable_revision(@ws_consumer, r.id, r.content_hash)

    assert obj.id == r.id

    # mismatched content_hash → rejected loud
    assert {:error, {:socialware_content_hash_mismatch, %{expected: "deadbeef", got: got}}} =
             DefinitionRegistry.resolve_installable_revision(@ws_consumer, r.id, "deadbeef")

    assert got == r.content_hash
  end

  test "T-CID-5: backward-compat — name-only install still resolves via bare-name lookup" do
    name = "cid5-#{uniq()}"
    write!(name, [Ezagent.ActionSet.Session], @ws_pub, :public)

    # No config_id supplied anywhere: the legacy name-keyed freeze path is unchanged.
    assert {:ok, frozen} =
             Installation.freeze_template_installs(%{installs: [name]}, @ws_consumer)

    assert {:ok, [{_d, obj, _i}]} = Installation.resolved_template_installs(frozen, @ws_consumer)
    assert is_binary(obj.content_hash)
  end

  test "T-CID-6: an unknown config_id is rejected loud" do
    assert {:error, {:unknown_socialware_revision, "no-such-revision"}} =
             DefinitionRegistry.resolve_installable_revision(@ws_consumer, "no-such-revision")
  end
end
