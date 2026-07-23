defmodule Ezagent.Architecture.CapAuthorityGenesisTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.Authority
  alias Ezagent.Ecto.KindCapAuthority

  test "genesis is one sealed insert and admin self-anchors without prior authority" do
    uri = unique_uri("once")
    admin = Ezagent.URI.user(:system, :admin)

    assert {:ok, first} = Authority.open(uri, :agent)
    assert {:ok, second} = Authority.open(uri, :agent)
    assert first.generation == 1
    assert second.key_id == first.key_id
    assert second.private_key == first.private_key

    assert [%KindCapAuthority{sealed: true, active: true}] =
             KindCapAuthority.list(Ezagent.URI.stable_key(uri))

    assert {:ok, anchor} = Authority.anchor(uri)
    assert anchor.instance == uri
    assert anchor.grantee_uri == admin
    assert Authority.verify(first, anchor, admin)

    assert %KindCapAuthority{sealed: true, active: true} =
             KindCapAuthority.active(Ezagent.URI.stable_key(admin))

    assert {:ok, admin_anchor} = Authority.anchor(admin)
    assert {:ok, admin_authority} = Authority.open(admin, :user)
    assert Authority.verify(admin_authority, admin_anchor, admin)
  end

  test "retired URI cannot silently rehydrate and admin re-genesis appends a generation" do
    uri = unique_uri("reincarnate")
    admin = Ezagent.URI.user(:system, :admin)
    attacker = Ezagent.URI.user(:system, :mallory)

    assert {:ok, first} = Authority.open(uri, :agent)
    assert :ok = Authority.retire(uri)
    assert {:error, :regenesis_required} = Authority.open(uri, :agent)
    assert {:error, :cap_context_required} = Authority.regenesis(uri, :agent, attacker)
    assert {:error, :cap_context_required} = Authority.regenesis(uri, :agent, admin)
    assert {:ok, second} = Authority.regenesis(uri, :agent)
    assert second.generation == first.generation + 1
    refute second.key_id == first.key_id

    assert [old, current] = KindCapAuthority.list(Ezagent.URI.stable_key(uri))
    refute old.active
    assert current.active
    assert old.sealed and current.sealed
  end

  test "product code contains no arbitrary genesis authorization tuple" do
    root = Path.expand("../../../..", __DIR__)

    offenders =
      root
      |> Path.join("apps/*/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(&contains_genesis_tuple?/1)
      |> Enum.map(&Path.relative_to(&1, root))

    assert offenders == [],
           "arbitrary {:genesis, uri} authorization survived:\n" <> Enum.join(offenders, "\n")
  end

  defp unique_uri(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/agent/test_authority-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp contains_genesis_tuple?(path) do
    with {:ok, ast} <- path |> File.read!() |> Code.string_to_quoted() do
      {_ast, found?} =
        Macro.prewalk(ast, false, fn
          {:genesis, _} = node, _found -> {node, true}
          {:{}, _, [:genesis, _]} = node, _found -> {node, true}
          node, found -> {node, found}
        end)

      found?
    else
      _ -> false
    end
  end
end
