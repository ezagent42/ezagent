defmodule EzagentWeb.Plugs.CloudflareRemoteIpTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias EzagentWeb.Plugs.CloudflareRemoteIp

  defp run(peer_ip, headers) do
    conn = conn(:post, "/login")
    conn = %{conn | remote_ip: peer_ip}
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    CloudflareRemoteIp.call(conn, CloudflareRemoteIp.init([]))
  end

  test "rewrites remote_ip from CF-Connecting-IP when the peer is a private IPv4 (the tunnel)" do
    conn = run({192, 168, 107, 7}, [{"cf-connecting-ip", "203.0.113.9"}])
    assert conn.remote_ip == {203, 0, 113, 9}
  end

  test "rewrites when the peer is the IPv4-mapped-IPv6 tunnel address (::ffff:192.168.107.7)" do
    # {0,0,0,0,0,0xffff, 0xC0A8, 0x6B07} == ::ffff:192.168.107.7
    conn = run({0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x6B07}, [{"cf-connecting-ip", "198.51.100.4"}])
    assert conn.remote_ip == {198, 51, 100, 4}
  end

  test "accepts an IPv6 client IP in the header" do
    conn = run({127, 0, 0, 1}, [{"cf-connecting-ip", "2001:db8::42"}])
    assert conn.remote_ip == {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x42}
  end

  test "IGNORES CF-Connecting-IP when the peer is PUBLIC (anti-spoof: direct exposure)" do
    conn = run({203, 0, 113, 200}, [{"cf-connecting-ip", "10.0.0.1"}])
    assert conn.remote_ip == {203, 0, 113, 200}
  end

  test "leaves remote_ip unchanged when there is no CF-Connecting-IP header" do
    conn = run({192, 168, 107, 7}, [])
    assert conn.remote_ip == {192, 168, 107, 7}
  end

  test "leaves remote_ip unchanged when the header is malformed" do
    conn = run({192, 168, 107, 7}, [{"cf-connecting-ip", "not-an-ip"}])
    assert conn.remote_ip == {192, 168, 107, 7}
  end
end
