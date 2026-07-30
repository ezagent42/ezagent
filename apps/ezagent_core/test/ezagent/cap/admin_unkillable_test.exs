defmodule Ezagent.Cap.AdminUnkillableTest do
  @moduledoc """
  #1627 B1-hybrid — the genesis admin (authority root) is STRUCTURALLY
  un-killable. Every bare gen-bump / revoke path REJECTS `admin_uri()`, so a
  "deliberately-killed admin" is an UNREACHABLE state (which is what makes the
  pre-epoch auto-heal of admin-only provably safe). The ONLY sanctioned way to
  advance the root's generation is `Authority.rotate_root_generation/2` (used by
  the atomic admin key-rotation operator command).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap
  alias Ezagent.Cap.Authority

  defp admin, do: Ezagent.URI.user(:system, :admin)

  defp regular_agent,
    do: Ezagent.URI.agent("team-alpha", "unkill-#{System.unique_integer([:positive])}")

  describe "the authority root is un-killable" do
    test "Cap.revoke_all_to/2 REJECTS the admin (early, before the handler)" do
      assert {:error, :root_authority_immutable} =
               Cap.revoke_all_to(admin(), %{authenticated_principal: admin(), caps: MapSet.new()})
    end

    test "Authority.regenesis/2 REJECTS the admin (the structural chokepoint)" do
      assert {:error, :root_authority_immutable} = Authority.regenesis(admin(), :user)
    end

    test "Authority.regenesis/3 REJECTS the admin (routes through /2)" do
      # A fully-authenticated ctx still cannot bare-bump the root.
      ctx = %{authenticated_principal: admin(), caps: MapSet.new()}
      assert {:error, reason} = Authority.regenesis(admin(), :user, ctx)
      assert reason in [:root_authority_immutable, :holder_revoked, :no_matching_cap]
    end

    test "a NON-admin is NOT root-rejected by revoke_all_to (reaches the normal flow)" do
      # A regular target is never `:root_authority_immutable`; it proceeds to the
      # normal authenticated flow (and fails there for lack of a real holder cap,
      # NOT for being the root).
      result =
        Cap.revoke_all_to(regular_agent(), %{
          authenticated_principal: regular_agent(),
          caps: MapSet.new()
        })

      refute match?({:error, :root_authority_immutable}, result)
    end
  end

  describe "sanctioned root rotation primitive" do
    test "rotate_root_generation/2 ADVANCES the admin generation (root-permitted)" do
      {:ok, gen1} = Authority.open(admin(), :user)
      assert {:ok, gen1_num} = Authority.current_generation(admin())

      assert {:ok, _rotated} = Authority.rotate_root_generation(admin(), :user)
      assert {:ok, gen2_num} = Authority.current_generation(admin())
      assert gen2_num == gen1_num + 1
      refute gen1 == nil
    end

    test "rotate_root_generation/2 REJECTS a non-root principal (no general bypass)" do
      assert {:error, :not_root_authority} =
               Authority.rotate_root_generation(regular_agent(), :agent)
    end
  end
end
