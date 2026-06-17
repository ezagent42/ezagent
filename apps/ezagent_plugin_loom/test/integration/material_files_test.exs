defmodule EzagentPluginLoom.Integration.MaterialFilesTest do
  @moduledoc "素材库文件树(/api,无 token):上传(保留文件夹)→ 列(带 url)→ 公开提供 → 删。"
  use ExUnit.Case, async: true
  use Plug.Test

  alias EzagentPluginLoom.{MaterialFiles, WebPlug}

  @opts WebPlug.init([])

  setup do
    ws = "loom-mf-#{System.unique_integer([:positive])}"
    sid = "main-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(MaterialFiles.dir(ws, sid)) end)
    %{ws: ws, sid: sid}
  end

  test "upload(带文件夹)→ list → serve → delete", ctx do
    tmp = Path.join(System.tmp_dir!(), "mf-#{System.unique_integer([:positive])}.txt")
    File.write!(tmp, "hello loom")
    upload = %Plug.Upload{path: tmp, filename: "a.txt", content_type: "text/plain"}

    up =
      conn(:post, "/api/#{ctx.ws}/#{ctx.sid}/materials/upload", %{
        "file" => upload,
        "path" => "docs/a.txt"
      })
      |> WebPlug.call(@opts)

    assert %{"ok" => true, "path" => "docs/a.txt"} = Jason.decode!(up.resp_body)

    # list:带相对路径 + url
    ls = conn(:get, "/api/#{ctx.ws}/#{ctx.sid}/materials") |> WebPlug.call(@opts)

    assert %{"ok" => true, "items" => [%{"path" => "docs/a.txt", "url" => url, "type" => "text"}]} =
             Jason.decode!(ls.resp_body)

    assert url == "/loom/materials/#{ctx.ws}/#{ctx.sid}/docs/a.txt"

    # serve:公开提供文件内容
    srv = conn(:get, "/materials/#{ctx.ws}/#{ctx.sid}/docs/a.txt") |> WebPlug.call(@opts)
    assert srv.status == 200
    assert srv.resp_body == "hello loom"

    # delete
    del =
      conn(:delete, "/api/#{ctx.ws}/#{ctx.sid}/materials?path=docs/a.txt") |> WebPlug.call(@opts)

    assert %{"ok" => true} = Jason.decode!(del.resp_body)
    assert MaterialFiles.list(ctx.ws, ctx.sid) == []
  end

  test "路径净化:.. 被剥离,文件不逃出 session 目录", ctx do
    tmp = Path.join(System.tmp_dir!(), "mf-#{System.unique_integer([:positive])}.txt")
    File.write!(tmp, "x")
    assert {:ok, rel} = MaterialFiles.save_file(ctx.ws, ctx.sid, "../../evil.txt", tmp)
    refute String.contains?(rel, "..")
    assert File.exists?(Path.join(MaterialFiles.dir(ctx.ws, ctx.sid), rel))
  end

  test "serve 未知文件 → 404", ctx do
    srv = conn(:get, "/materials/#{ctx.ws}/#{ctx.sid}/nope.png") |> WebPlug.call(@opts)
    assert srv.status == 404
  end
end
