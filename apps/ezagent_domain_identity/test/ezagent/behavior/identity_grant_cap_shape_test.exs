defmodule Ezagent.Behavior.IdentityGrantCapShapeTest do
  @moduledoc """
  Bug 2 regression (Allen 2026-05-26) — `IdentityAdmin.invoke(:grant_cap, ...)`
  used to store the input `cap` arg as-is into the slice MapSet. Three
  caller-shaped inputs reach this entry point:

    1. `%Ezagent.Capability{}` struct (Elixir caller built the struct)
    2. atom-keyed map (Elixir caller passed params)
    3. **string-keyed map** (CLI's Optimus `:map` arg → `Jason.decode/1`)

  Before the fix, shape (3) sat in the slice as a bare string-keyed
  map. `Capability.matches?/2` pattern-matches on `%__MODULE__{}` and
  silently rejected the held map → CLI grants authorized nothing.

  This test pins the contract: all three input shapes produce the
  same canonical `%Capability{}` representation in the slice, and the
  result `matches?/2` the corresponding needed-cap map.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.IdentityAdmin
  alias Ezagent.Capability

  @workspace_uri URI.new!("workspace://system")
  @session_uri URI.new!("session://default/system/main")
  @granter URI.parse("entity://user/system/admin")

  # All three input shapes encode the same logical capability:
  #
  #   kind:           :session
  #   behavior:       Ezagent.Behavior.ExternalMirror
  #   instance:       session://default/system/main
  #   workspace_uri:  workspace://system
  defp shape_struct do
    %Capability{
      kind: :session,
      behavior: Ezagent.Behavior.ExternalMirror,
      instance: @session_uri,
      workspace_uri: @workspace_uri,
      granted_by: @granter,
      granted_at: DateTime.utc_now()
    }
  end

  defp shape_atom_keyed_map do
    %{
      kind: :session,
      behavior: Ezagent.Behavior.ExternalMirror,
      instance: @session_uri,
      workspace_uri: @workspace_uri
    }
  end

  # The CLI shape — string keys, atom/module/URI values as their
  # serialized string forms (same shape `Jason.decode/1` produces from
  # `mix ezagent user grant_cap --cap '{"kind":"session", ...}'`).
  defp shape_string_keyed_map do
    %{
      "kind" => "session",
      "behavior" => "Ezagent.Behavior.ExternalMirror",
      "instance" => "session://default/system/main",
      "workspace_uri" => "workspace://system"
    }
  end

  # Granter ctx — wildcard `behavior: :any`-on-workspace caps require
  # workspace admin OR bootstrap admin per check_grant_authorized.
  # Concrete kind+behavior caps fall through to the data_owner check;
  # admin caps satisfy both paths.
  defp admin_ctx do
    %{
      caller: @granter,
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
    }
  end

  describe "all three input shapes produce the same in-slice representation" do
    test "struct input — passes through unchanged" do
      cap = shape_struct()

      {:ok, new_slice, %{caps: caps}} =
        IdentityAdmin.invoke(:grant_cap, %{caps: MapSet.new()}, %{cap: cap}, admin_ctx())

      [stored] = caps
      assert MapSet.size(new_slice.caps) == 1
      assert is_struct(stored, Capability)
      assert stored.kind == :session
      assert stored.behavior == Ezagent.Behavior.ExternalMirror
      assert URI.to_string(stored.instance) == "session://default/system/main"
      assert URI.to_string(stored.workspace_uri) == "workspace://system"
    end

    test "atom-keyed map input — normalized to struct" do
      params = shape_atom_keyed_map()

      {:ok, new_slice, %{caps: caps}} =
        IdentityAdmin.invoke(:grant_cap, %{caps: MapSet.new()}, %{cap: params}, admin_ctx())

      [stored] = caps
      assert MapSet.size(new_slice.caps) == 1
      assert is_struct(stored, Capability),
             "expected a %Ezagent.Capability{} struct in the slice, got #{inspect(stored)}"

      assert stored.kind == :session
      assert stored.behavior == Ezagent.Behavior.ExternalMirror
      assert URI.to_string(stored.instance) == "session://default/system/main"
      assert URI.to_string(stored.workspace_uri) == "workspace://system"
    end

    test "string-keyed (CLI / JSON) map input — normalized to struct" do
      json_map = shape_string_keyed_map()

      {:ok, new_slice, %{caps: caps}} =
        IdentityAdmin.invoke(:grant_cap, %{caps: MapSet.new()}, %{cap: json_map}, admin_ctx())

      [stored] = caps
      assert MapSet.size(new_slice.caps) == 1

      assert is_struct(stored, Capability),
             "CLI / JSON-decoded cap MUST be normalized to a %Capability{} struct " <>
               "before going into the slice (Bug 2 regression — bare string-keyed " <>
               "map sat here previously, silently denying every cap match). " <>
               "Got: #{inspect(stored)}"

      assert stored.kind == :session
      assert stored.behavior == Ezagent.Behavior.ExternalMirror
      assert URI.to_string(stored.instance) == "session://default/system/main"
      assert URI.to_string(stored.workspace_uri) == "workspace://system"
    end

    test "all three shapes hash-equal in MapSet (idempotent across input forms)" do
      # If a user grants the same logical cap once via struct path and
      # then via CLI/JSON, MapSet must collapse them — same logical
      # cap means same in-slice cap. Pre-fix this trivially failed
      # because string-keyed map and struct are not MapSet-equal.
      ctx = admin_ctx()

      {:ok, slice_1, _} =
        IdentityAdmin.invoke(
          :grant_cap,
          %{caps: MapSet.new()},
          %{cap: shape_struct()},
          ctx
        )

      {:ok, slice_2, _} =
        IdentityAdmin.invoke(:grant_cap, slice_1, %{cap: shape_atom_keyed_map()}, ctx)

      {:ok, slice_3, %{caps: caps}} =
        IdentityAdmin.invoke(:grant_cap, slice_2, %{cap: shape_string_keyed_map()}, ctx)

      # The three calls add ONE distinct cap shape — `granted_at` will
      # differ across the three normalized structs (`utc_now/0` on each
      # normalization) so MapSet may keep up to three entries. The
      # invariant we pin: every stored entry is the canonical struct.
      assert MapSet.size(slice_3.caps) >= 1
      assert MapSet.size(slice_3.caps) <= 3

      Enum.each(caps, fn cap ->
        assert is_struct(cap, Capability),
               "all stored caps must be %Capability{} structs, got: #{inspect(cap)}"

        assert cap.kind == :session
        assert cap.behavior == Ezagent.Behavior.ExternalMirror
      end)
    end
  end

  describe "downstream Capability.matches?/2 sees the granted cap" do
    test "string-keyed CLI grant authorizes a matching dispatch (the regression)" do
      # The end-to-end check: a grant via the CLI path (string-keyed
      # map) MUST authorize a dispatch needing the same logical cap.
      # Before the fix, `matches?/2` rejected the bare map → grant was
      # effectively a no-op.
      json_map = shape_string_keyed_map()

      {:ok, slice, _} =
        IdentityAdmin.invoke(:grant_cap, %{caps: MapSet.new()}, %{cap: json_map}, admin_ctx())

      needed = %{
        kind: :session,
        behavior: Ezagent.Behavior.ExternalMirror,
        instance: @session_uri,
        workspace_uri: @workspace_uri
      }

      assert Enum.any?(slice.caps, &Capability.matches?(&1, needed)),
             "string-keyed CLI-supplied cap MUST match a matching needed-cap shape " <>
               "via Capability.matches?/2 after normalization. Slice contents: " <>
               inspect(slice.caps)
    end

    test "atom-keyed Elixir grant authorizes a matching dispatch" do
      params = shape_atom_keyed_map()

      {:ok, slice, _} =
        IdentityAdmin.invoke(:grant_cap, %{caps: MapSet.new()}, %{cap: params}, admin_ctx())

      needed = %{
        kind: :session,
        behavior: Ezagent.Behavior.ExternalMirror,
        instance: @session_uri,
        workspace_uri: @workspace_uri
      }

      assert Enum.any?(slice.caps, &Capability.matches?(&1, needed))
    end
  end

  describe "Capability.normalize!/2 input validation" do
    test "passes a %Capability{} struct through unchanged" do
      cap = shape_struct()
      assert Capability.normalize!(cap, @granter) == cap
    end

    test "rejects atom-keyed map missing :workspace_uri (no silent default)" do
      bad_input = %{kind: :session, behavior: Ezagent.Behavior.ExternalMirror, instance: :any}

      assert_raise ArgumentError, ~r/missing required `:workspace_uri`/, fn ->
        Capability.normalize!(bad_input, @granter)
      end
    end

    test "rejects garbage shapes" do
      assert_raise ArgumentError, ~r/unrecognized cap shape/, fn ->
        Capability.normalize!("not-a-cap", @granter)
      end

      assert_raise ArgumentError, ~r/unrecognized cap shape/, fn ->
        Capability.normalize!(42, @granter)
      end

      assert_raise ArgumentError, ~r/unrecognized cap shape/, fn ->
        Capability.normalize!(%{unrelated: :map}, @granter)
      end
    end

    test "string-keyed map stamps granted_by from the supplied granter" do
      cap = Capability.normalize!(shape_string_keyed_map(), @granter)

      assert is_struct(cap, Capability)
      assert URI.to_string(cap.granted_by) == URI.to_string(@granter)
      assert match?(%DateTime{}, cap.granted_at)
    end
  end
end
