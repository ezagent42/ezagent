defmodule Ezagent.E2E.ManifestTest do
  use ExUnit.Case, async: true
  alias Ezagent.E2E.Manifest

  test "ctx round-trips %URI{} as %URI{}, primitives as-is, across encode→decode" do
    uri = URI.new!("entity://agent/system/cc_relay")

    m = %Manifest{
      scenario_id: "s34",
      step_index: 2,
      step_name: "seed-relay-cc",
      fp: "abc123",
      assert_passed: true,
      ctx: %{"relay_cc" => uri, "count" => 3, "name" => "x", "flag" => true, "nested" => %{"u" => uri}, "list" => [uri, "s"]}
    }

    assert {:ok, json} = Manifest.encode(m)
    assert {:ok, d} = Manifest.decode(json)

    assert %URI{} = d.ctx["relay_cc"]
    assert d.ctx["relay_cc"] == uri
    assert d.ctx["count"] == 3
    assert d.ctx["name"] == "x"
    assert d.ctx["flag"] == true
    assert d.ctx["nested"]["u"] == uri
    assert [^uri, "s"] = d.ctx["list"]
    assert d.schema_version == 1
    assert d.assert_passed == true and d.step_index == 2 and d.fp == "abc123"
  end

  test "atom ctx VALUE → clear encode error (codex r4: no silent shape change)" do
    assert {:error, {:unencodable_ctx_value, :boom}} =
             Manifest.encode(%Manifest{ctx: %{"k" => :boom}})
  end

  test "atom ctx KEY → clear encode error (keys must be strings)" do
    assert {:error, {:unencodable_ctx_key, :atom_key}} =
             Manifest.encode(%Manifest{ctx: %{atom_key: "v"}})
  end

  test "MapSet ctx value → rejected (caps rebuilt from principals, not stashed)" do
    assert {:error, {:unencodable_ctx_value, _}} =
             Manifest.encode(%Manifest{ctx: %{"caps" => MapSet.new([:a])}})
  end

  test "schema_version mismatch on decode → clear error" do
    json = Jason.encode!(%{"schema_version" => 999, "ctx" => %{}})
    assert {:error, {:schema_version_mismatch, 999, 1}} = Manifest.decode(json)
  end

  test "user map carrying the reserved __uri__ key → encode error (no tag collision)" do
    assert {:error, {:reserved_ctx_key, "__uri__"}} =
             Manifest.encode(%Manifest{ctx: %{"e" => %{"__uri__" => "x", "other" => 1}}})

    assert {:error, {:reserved_ctx_key, "__uri__"}} =
             Manifest.encode(%Manifest{ctx: %{"__uri__" => "x"}})
  end

  test "decode preserves a multi-key __uri__ map as a MAP, never coercing to URI (no drop)" do
    json = Jason.encode!(%{"schema_version" => 1, "ctx" => %{"e" => %{"__uri__" => "x", "other" => 1}}})
    assert {:ok, d} = Manifest.decode(json)
    assert d.ctx["e"] == %{"__uri__" => "x", "other" => 1}
  end
end
