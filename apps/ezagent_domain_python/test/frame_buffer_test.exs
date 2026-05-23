defmodule EzagentDomainPython.FrameBufferTest do
  use ExUnit.Case, async: true

  alias EzagentDomainPython.{FrameBuffer, JsonRpc}

  defp wire(env), do: env |> JsonRpc.encode_frame() |> IO.iodata_to_binary()

  test "feed/2 emits one complete frame when delivered whole" do
    bytes = wire({:notification, "ping", %{}})
    {_buf, [body]} = FrameBuffer.feed(FrameBuffer.new(), bytes)
    assert {:ok, {:notification, "ping", %{}}} = JsonRpc.decode_body(body)
  end

  test "incremental parsing across chunk boundaries" do
    bytes = wire({:request, 1, "behavior.invoke", %{"k" => "v"}})

    {buf, []} = FrameBuffer.feed(FrameBuffer.new(), binary_part(bytes, 0, 10))
    {buf, []} = FrameBuffer.feed(buf, binary_part(bytes, 10, byte_size(bytes) - 15))
    {_buf, [body]} = FrameBuffer.feed(buf, binary_part(bytes, byte_size(bytes) - 5, 5))

    assert {:ok, {:request, 1, "behavior.invoke", %{"k" => "v"}}} =
             JsonRpc.decode_body(body)
  end

  test "back-to-back frames in one chunk decode separately" do
    bytes = wire({:result, 7, %{"a" => 1}}) <> wire({:notification, "log", %{"msg" => "hi"}})

    {buf, [body1, body2]} = FrameBuffer.feed(FrameBuffer.new(), bytes)
    assert {:ok, {:result, 7, %{"a" => 1}}} = JsonRpc.decode_body(body1)
    assert {:ok, {:notification, "log", %{"msg" => "hi"}}} = JsonRpc.decode_body(body2)
    assert buf.buffer == <<>>
  end

  test "frame with embedded newline in body decodes correctly" do
    payload = %{"line" => "first\nsecond\r\nthird"}
    bytes = wire({:result, 1, payload})

    {_buf, [body]} = FrameBuffer.feed(FrameBuffer.new(), bytes)
    assert {:ok, {:result, 1, ^payload}} = JsonRpc.decode_body(body)
  end

  test "frame with binary-like body bytes (high octets) decodes correctly" do
    high_bytes = for n <- 128..255, into: "", do: <<n>>
    payload = %{"data" => Base.encode64(high_bytes)}
    bytes = wire({:result, 1, payload})
    {_buf, [body]} = FrameBuffer.feed(FrameBuffer.new(), bytes)
    assert {:ok, {:result, 1, ^payload}} = JsonRpc.decode_body(body)
  end

  test "header-only chunk waits for body" do
    bytes = wire({:notification, "ping", %{}})
    [header, body] = String.split(bytes, "\r\n\r\n", parts: 2)
    {buf, []} = FrameBuffer.feed(FrameBuffer.new(), header <> "\r\n\r\n")
    {_buf, [out]} = FrameBuffer.feed(buf, body)
    assert {:ok, {:notification, "ping", %{}}} = JsonRpc.decode_body(out)
  end

  test "malformed Content-Length raises" do
    assert_raise ArgumentError, fn ->
      FrameBuffer.feed(FrameBuffer.new(), "Content-Length: abc\r\n\r\n{}")
    end
  end

  test "missing Content-Length raises" do
    assert_raise ArgumentError, fn ->
      FrameBuffer.feed(FrameBuffer.new(), "X-Other: yes\r\n\r\n{}")
    end
  end
end
