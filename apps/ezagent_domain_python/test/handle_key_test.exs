defmodule Ezagent.Domain.Python.HandleKeyTest do
  @moduledoc """
  SPEC §1.2.1 / §9.3 (round-2 HIGH-3) — strict handle canonicalization.

  Each of the 6 negative cases enumerated in the SPEC gets its own
  assertion. handle_key/1 MUST raise ArgumentError, not silently bind
  to a different Registry key.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Domain.Python

  describe "positive: round-trip equivalence" do
    test "URI struct and its URI.to_string/1 produce the same key" do
      uri = URI.parse("system://python/default")
      assert Python.handle_key(uri) == Python.handle_key(URI.to_string(uri))
    end

    test "test:// fixture binary is admitted as identity" do
      assert Python.handle_key("test://abc/123") == "test://abc/123"
    end
  end

  describe "negative: 6 cases that must raise (SPEC §1.2.1)" do
    test "uppercase scheme raises" do
      # URI parser preserves scheme case differently across stdlib
      # versions; what matters is canonical(input) != input AND/OR the
      # scheme is unregistered. Either way handle_key MUST raise.
      assert_raise ArgumentError, fn ->
        Python.handle_key("SYSTEM://python/default")
      end
    end

    test "trailing slash raises (non-canonical)" do
      assert_raise ArgumentError, fn ->
        Python.handle_key("system://python/default/")
      end
    end

    test "percent-encoded segment raises" do
      # %64 == 'd' — canonical form differs from the encoded input.
      assert_raise ArgumentError, fn ->
        Python.handle_key("system://python/%64efault")
      end
    end

    test "nil raises" do
      assert_raise ArgumentError, fn -> Python.handle_key(nil) end
    end

    test "atom raises" do
      assert_raise ArgumentError, fn -> Python.handle_key(:my_atom) end
    end

    test "not a URI / not a binary raises" do
      assert_raise ArgumentError, fn -> Python.handle_key({:tuple, :form}) end
      assert_raise ArgumentError, fn -> Python.handle_key(123) end
      assert_raise ArgumentError, fn -> Python.handle_key(%{not: :a_uri}) end
    end

    test "test:// outside the 'test://' admit prefix is rejected" do
      # A binary like "garbage" hits the parse!/1 path and fails.
      assert_raise ArgumentError, fn -> Python.handle_key("not-a-uri") end
    end
  end
end
