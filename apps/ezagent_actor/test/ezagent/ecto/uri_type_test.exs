defmodule Ezagent.Ecto.URITest do
  use ExUnit.Case, async: true
  alias Ezagent.Ecto.URI, as: URIType

  describe "type/0" do
    test "is :string (column type in DB)" do
      assert URIType.type() == :string
    end
  end

  describe "cast/1" do
    test "accepts %URI{} struct unchanged" do
      uri = URI.new!("entity://team-alpha/agent/test_cc-builder")
      assert {:ok, ^uri} = URIType.cast(uri)
    end

    test "accepts string + parses to %URI{}" do
      assert {:ok, %URI{} = uri} = URIType.cast("entity://team-alpha/agent/test_cc-builder")
      assert uri.scheme == "entity"
      assert uri.host == "team-alpha"
      assert uri.path == "/agent/test_cc-builder"
    end

    test "rejects non-URI non-string input" do
      assert :error = URIType.cast(123)
      assert :error = URIType.cast(%{})
      assert :error = URIType.cast(nil)
    end
  end

  describe "load/1" do
    test "DB string → %URI{} struct" do
      assert {:ok, %URI{} = uri} = URIType.load("session://system/default/main")
      assert uri.scheme == "session"
      assert uri.host == "system"
      assert uri.path == "/default/main"
    end

    test "rejects non-string" do
      assert :error = URIType.load(123)
      assert :error = URIType.load(nil)
    end
  end

  describe "dump/1" do
    test "%URI{} → DB string" do
      uri = URI.new!("entity://system/user/admin")
      assert {:ok, "entity://system/user/admin"} = URIType.dump(uri)
    end

    test "accepts already-string (idempotent)" do
      assert {:ok, "session://system/default/main"} =
               URIType.dump("session://system/default/main")
    end

    test "rejects others" do
      assert :error = URIType.dump(123)
      assert :error = URIType.dump(nil)
    end
  end

  describe "round-trip" do
    test "cast → dump → load preserves URI semantics" do
      original = URI.new!("entity://team-alpha/agent/test_cc-builder")
      {:ok, casted} = URIType.cast(original)
      {:ok, dumped} = URIType.dump(casted)
      {:ok, loaded} = URIType.load(dumped)

      assert loaded == original
    end
  end
end
