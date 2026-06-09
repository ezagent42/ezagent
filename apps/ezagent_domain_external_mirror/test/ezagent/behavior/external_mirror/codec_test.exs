defmodule Ezagent.Behavior.ExternalMirror.CodecTest do
  @moduledoc """
  Unit tests for `Ezagent.Behavior.ExternalMirror.Codec` — the pure
  data-mapping / opts-codec helpers extracted from
  `Ezagent.Behavior.ExternalMirror` (#25 Phase-3, PR-3N).

  Pure functions only: no DB, no effects, no sandbox needed.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.ExternalMirror.Codec
  alias Ezagent.ExternalMirror.BindingRow

  describe "encode_opts/1 + decode_opts/1" do
    test "round-trips a string-keyed map" do
      assert Codec.encode_opts(%{"k" => "v", "n" => 1}) |> Codec.decode_opts() ==
               %{"k" => "v", "n" => 1}
    end

    test "encode_opts/1 falls back to \"{}\" for non-maps" do
      assert Codec.encode_opts(:nope) == "{}"
      assert Codec.encode_opts(nil) == "{}"
    end

    test "decode_opts/1 returns %{} for garbage / non-binary" do
      assert Codec.decode_opts("not json") == %{}
      assert Codec.decode_opts(nil) == %{}
      assert Codec.decode_opts("[1,2,3]") == %{}
    end

    test "decode_opts/1 does NOT atomize keys (atom-table DoS guard)" do
      decoded = Codec.decode_opts(~s({"arbitrary_caller_key":1}))
      assert decoded == %{"arbitrary_caller_key" => 1}
      assert Map.keys(decoded) == ["arbitrary_caller_key"]
    end
  end

  describe "unique_constraint_violation?/1" do
    test "true when a changeset error carries constraint: :unique" do
      cs = %Ecto.Changeset{
        errors: [id: {"has already been taken", [constraint: :unique, constraint_name: "x"]}]
      }

      assert Codec.unique_constraint_violation?(cs)
    end

    test "false for non-unique / validation errors" do
      cs = %Ecto.Changeset{errors: [adapter_id: {"can't be blank", [validation: :required]}]}
      refute Codec.unique_constraint_violation?(cs)
    end

    test "false for an empty changeset" do
      refute Codec.unique_constraint_violation?(%Ecto.Changeset{errors: []})
    end
  end

  describe "row_to_slice_binding/1" do
    test "maps a BindingRow to the slice's human-readable binding shape" do
      row = %BindingRow{
        id: "deadbeef",
        session_uri: "session://default/s1",
        adapter_id: "lark",
        target_id: "chat-123",
        opts_json: ~s({"label":"ops"}),
        bound_by: "entity://default/user/admin",
        bound_at: ~U[2026-06-09 00:00:00.000000Z]
      }

      assert %{
               binding_id: "lark/chat-123",
               adapter_id: "lark",
               target_id: "chat-123",
               opts: %{"label" => "ops"},
               bound_at: ~U[2026-06-09 00:00:00.000000Z]
             } = Codec.row_to_slice_binding(row)

      assert %URI{} = Codec.row_to_slice_binding(row).bound_by
    end
  end
end
