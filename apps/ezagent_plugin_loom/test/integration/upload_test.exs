defmodule EzagentPluginLoom.Integration.UploadTest do
  @moduledoc "SDK-v2:/api/:ws/:sid/upload → resource:// + /uploads/:name serve + /resource 解析跳转。"
  use ExUnit.Case, async: true
  use Plug.Test

  alias EzagentPluginLoom.WebPlug

  @opts WebPlug.init([])

  setup do
    %{
      ws: "loom-up-#{System.unique_integer([:positive])}",
      sid: "main-#{System.unique_integer([:positive])}"
    }
  end

  defp upload(content, filename, ctype \\ "image/png") do
    tmp = Path.join(System.tmp_dir!(), "up-#{System.unique_integer([:positive])}")
    File.write!(tmp, content)
    %Plug.Upload{path: tmp, filename: filename, content_type: ctype}
  end

  test "upload → resource uri → /uploads serve → /resource 302", ctx do
    up =
      conn(:post, "/api/#{ctx.ws}/#{ctx.sid}/upload", %{"file" => upload("PNGDATA", "pic.png")})
      |> WebPlug.call(@opts)

    assert %{"ok" => true, "uri" => uri, "stored_name" => stored} = Jason.decode!(up.resp_body)
    assert uri == "resource://uploads/#{ctx.ws}/#{stored}"

    # serve
    srv = conn(:get, "/uploads/#{stored}") |> WebPlug.call(@opts)
    assert srv.status == 200
    assert srv.resp_body == "PNGDATA"

    # resource 解析 → 302 /loom/uploads/<stored>
    res =
      conn(:get, "/api/#{ctx.ws}/#{ctx.sid}/resource?uri=#{URI.encode_www_form(uri)}")
      |> WebPlug.call(@opts)

    assert res.status == 302
    assert {"location", "/loom/uploads/" <> _} = List.keyfind(res.resp_headers, "location", 0)
  end

  test "跨 workspace 的 resource 被拒", ctx do
    bad = "resource://uploads/other-ws/x.png"

    res =
      conn(:get, "/api/#{ctx.ws}/#{ctx.sid}/resource?uri=#{URI.encode_www_form(bad)}")
      |> WebPlug.call(@opts)

    assert res.status == 400
    assert %{"ok" => false} = Jason.decode!(res.resp_body)
  end

  test "blocklist 扩展名被拒", ctx do
    up =
      conn(:post, "/api/#{ctx.ws}/#{ctx.sid}/upload", %{
        "file" => upload("MZ", "evil.exe", "application/octet-stream")
      })
      |> WebPlug.call(@opts)

    assert %{"ok" => false, "error" => "ext_blocked"} = Jason.decode!(up.resp_body)
  end
end
