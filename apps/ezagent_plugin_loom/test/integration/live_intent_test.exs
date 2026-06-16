defmodule EzagentPluginLoom.Integration.LiveIntentTest do
  @moduledoc """
  意图推荐(Intent):非-live 验 HTTP 鉴(bad request)；live 验真实 LLM 选品。
  需 `ANTHROPIC_*` 跑 live: `... mix test --include live <this>`。
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias EzagentPluginLoom.{Intent, WebPlug}

  @opts WebPlug.init([])

  @catalog [
    %{"id" => "p1", "name" => "手冲咖啡套装", "desc" => "V60 滤杯 + 手冲壶"},
    %{"id" => "p2", "name" => "意式浓缩机", "desc" => "家用半自动咖啡机"},
    %{"id" => "p3", "name" => "挂耳咖啡", "desc" => "便携挂耳,办公室首选"},
    %{"id" => "p4", "name" => "保温杯", "desc" => "不锈钢保温杯"}
  ]

  test "POST /intent rejects empty intent" do
    conn =
      conn(:post, "/intent", Jason.encode!(%{intent: "", catalog: @catalog}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert conn.status == 400
  end

  @tag :live
  test "Intent.recommend hard-selects matching products with pitches" do
    assert {:ok, picks} = Intent.recommend("我想在办公室喝咖啡，方便快捷", @catalog, n: 2)

    assert is_list(picks)
    assert length(picks) >= 1 and length(picks) <= 2
    valid_ids = MapSet.new(["p1", "p2", "p3", "p4"])

    assert Enum.all?(picks, fn p ->
             MapSet.member?(valid_ids, p["id"]) and is_binary(p["pitch"]) and p["pitch"] != ""
           end)
  end

  @tag :live
  test "POST /intent returns recommendations end-to-end" do
    conn =
      conn(:post, "/intent", Jason.encode!(%{intent: "送礼用的高端咖啡装备", catalog: @catalog}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert conn.status == 200
    assert %{"ok" => true, "picks" => picks} = Jason.decode!(conn.resp_body)
    assert is_list(picks) and picks != []
  end
end
