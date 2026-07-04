defmodule Ezagent.Socialware.ContentHashTest do
  # T-Id-a (§8.5) — content-hash artifact identity: deterministic, recursive
  # key-sorted canonicalization so the SAME manifest hashes identically
  # regardless of key order or atom-vs-string keys, and DIFFERS when any body
  # field changes.
  use ExUnit.Case, async: true

  alias Ezagent.Socialware.Definition

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "hashy",
        title: "T",
        description: "orig",
        bases: [Ezagent.ActionSet.Session],
        shape: [],
        visibility_policy: %{scope: :private, publish_policy: :auto, web_anon_access: false}
      },
      overrides
    )
  end

  test "T-Id-a: env-independent — the same manifest bytes hash equal (workspace not in body)" do
    {:ok, definition} = Definition.new(attrs())
    # A manifest authored in two 'environments' carries no env-local data, so
    # its content-hash is identical anywhere.
    assert Definition.content_hash(Definition.body(definition)) ==
             Definition.content_hash(Definition.body(definition))
  end

  test "T-Id-a: hash differs when any body field changes" do
    {:ok, a} = Definition.new(attrs())
    {:ok, b} = Definition.new(attrs(%{description: "edited"}))

    refute Definition.content_hash(Definition.body(a)) ==
             Definition.content_hash(Definition.body(b))
  end

  test "T-Id-a: round-trip stable — atom-keyed fresh body == JSON-round-tripped persisted body" do
    # This is the invariant the `:exists` no-op path depends on: a fresh
    # atom-keyed `Definition.body/1` and its Jason/Ecto-persisted string-keyed
    # form must produce the SAME hash.
    {:ok, definition} = Definition.new(attrs())
    fresh = Definition.body(definition)
    persisted = fresh |> Jason.encode!() |> Jason.decode!()

    assert Definition.content_hash(fresh) == Definition.content_hash(persisted)
  end

  test "T-Id-a: recursive key sorting — nested-map key order does not change the hash" do
    a = %{
      "name" => "x",
      "visibility_policy" => %{"scope" => "public", "web_anon_access" => true}
    }

    b = %{
      "visibility_policy" => %{"web_anon_access" => true, "scope" => "public"},
      "name" => "x"
    }

    assert Definition.content_hash(a) == Definition.content_hash(b)
  end

  test "T-Id-a: atom keys and string keys canonicalize to the same hash" do
    assert Definition.content_hash(%{name: "x", version: "0.1.0"}) ==
             Definition.content_hash(%{"name" => "x", "version" => "0.1.0"})
  end
end
