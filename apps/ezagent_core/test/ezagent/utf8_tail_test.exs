defmodule Ezagent.Utf8TailTest do
  @moduledoc """
  Unit tests for the codepoint-boundary-aware trailing slice (#1201 ①).
  """
  use ExUnit.Case, async: true

  alias Ezagent.Utf8Tail

  test "returns the binary unchanged when it already fits" do
    assert Utf8Tail.tail("hello", 5) == "hello"
    assert Utf8Tail.tail("hello", 100) == "hello"
    assert Utf8Tail.tail("", 10) == ""
  end

  test "pure-ASCII tail is an exact byte-boundary cut" do
    bin = String.duplicate("abcdefgh", 100)
    tail = Utf8Tail.tail(bin, 13)
    assert byte_size(tail) == 13
    assert tail == binary_part(bin, byte_size(bin) - 13, 13)
    assert String.valid?(tail)
  end

  test "cut landing mid-CJK-codepoint advances past continuation bytes" do
    # "中" is 3 bytes; a 16_384-byte tail of a 18_000-byte pure-中 run cuts at
    # offset 1_616 ≡ 2 (mod 3) — the LAST continuation byte of a codepoint —
    # so the raw cut starts with 1 continuation byte; the aligned cut drops it.
    bin = String.duplicate("中", 6_000)

    raw = binary_part(bin, byte_size(bin) - 16_384, 16_384)
    refute String.valid?(raw)

    tail = Utf8Tail.tail(bin, 16_384)
    assert String.valid?(tail)
    assert byte_size(tail) == 16_383
    assert String.starts_with?(tail, "中")
  end

  test "cut landing exactly on a codepoint boundary is not shrunk" do
    bin = String.duplicate("中", 6_000)
    # 16_383 = 3 * 5_461 → boundary-aligned already.
    tail = Utf8Tail.tail(bin, 16_383)
    assert byte_size(tail) == 16_383
    assert String.valid?(tail)
  end

  test "4-byte codepoints (emoji) are respected" do
    bin = "x" <> String.duplicate("😀", 100)
    # 😀 is 4 bytes; ask for a tail that lands mid-emoji at every offset.
    for keep <- 5..12 do
      tail = Utf8Tail.tail(bin, keep)
      assert String.valid?(tail), "keep=#{keep} produced invalid UTF-8"
    end
  end

  test "genuinely invalid input: advancement is capped at 3 bytes" do
    # 10 continuation bytes in a row can never be valid UTF-8; the helper
    # must not scan unboundedly — it advances at most 3 and cuts anyway.
    bin = String.duplicate("a", 100) <> :binary.copy(<<0x80>>, 10) <> "zz"
    tail = Utf8Tail.tail(bin, 10)
    # started at byte 102 (a continuation byte), advanced 3, cut at 105.
    assert byte_size(tail) == 7
  end
end
