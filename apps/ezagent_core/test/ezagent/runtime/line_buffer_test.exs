defmodule Ezagent.Runtime.LineBufferTest do
  use ExUnit.Case, async: true

  alias Ezagent.Runtime.LineBuffer

  describe "new/1" do
    test "returns a LineBuffer struct with the given max bytes" do
      lb = LineBuffer.new(1024)
      assert lb.max == 1024
      assert lb.buf == ""
    end
  end

  describe "feed/2" do
    test "accumulates partial lines in buffer" do
      lb = LineBuffer.new(1024)
      {lb2, lines} = LineBuffer.feed(lb, "hello")
      assert lines == []
      assert lb2.buf == "hello"
    end

    test "emits a complete line when newline arrives" do
      lb = LineBuffer.new(1024)
      {lb2, lines} = LineBuffer.feed(lb, "hello\nworld")
      assert lines == ["hello"]
      assert lb2.buf == "world"
    end

    test "strips \\r from \\r\\n line endings" do
      lb = LineBuffer.new(1024)
      {lb2, lines} = LineBuffer.feed(lb, "hello\r\nworld\r\n")
      assert lines == ["hello", "world"]
      assert lb2.buf == ""
    end

    test "handles multiple complete lines in one chunk" do
      lb = LineBuffer.new(1024)
      {lb2, lines} = LineBuffer.feed(lb, "line1\nline2\nline3\n")
      assert lines == ["line1", "line2", "line3"]
      assert lb2.buf == ""
    end

    test "assembles a line from multiple partial chunks" do
      lb = LineBuffer.new(1024)
      {lb2, lines1} = LineBuffer.feed(lb, "hel")
      assert lines1 == []
      {lb3, lines2} = LineBuffer.feed(lb2, "lo\n")
      assert lines2 == ["hello"]
      assert lb3.buf == ""
    end

    test "caps an over-long line instead of growing forever" do
      lb = LineBuffer.new(8)
      # 18 bytes, no \n — should flush capped prefix of 8 bytes
      {_lb, lines} = LineBuffer.feed(lb, "AAAAAAAAAAAAAAAAAA")
      assert lines == ["AAAAAAAA"]
    end

    test "after capping, keeps the remainder and emits normally when newline arrives" do
      lb = LineBuffer.new(8)
      # 18 bytes no \n — emit cap prefix "AAAAAAAA" (8), keep "AAAAAAAAAA" (10) in buf
      {lb2, lines1} = LineBuffer.feed(lb, "AAAAAAAAAAAAAAAAAA")
      assert lines1 == ["AAAAAAAA"]
      assert lb2.buf == "AAAAAAAAAA"
      # feed a newline — "AAAAAAAAAA\n" is a complete line, emitted whole
      # (cap only guards the unbounded no-newline growth; a line terminated by \n passes through)
      {lb3, lines2} = LineBuffer.feed(lb2, "\n")
      assert lines2 == ["AAAAAAAAAA"]
      assert lb3.buf == ""
    end

    test "empty binary is a no-op" do
      lb = LineBuffer.new(1024)
      {lb2, lines} = LineBuffer.feed(lb, "")
      assert lines == []
      assert lb2.buf == ""
    end

    test "lone newline flushes empty string" do
      lb = LineBuffer.new(1024)
      {lb2, lines} = LineBuffer.feed(lb, "\n")
      assert lines == [""]
      assert lb2.buf == ""
    end
  end
end
