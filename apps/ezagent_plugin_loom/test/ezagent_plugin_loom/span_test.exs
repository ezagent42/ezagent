defmodule EzagentPluginLoom.SpanTest do
  use ExUnit.Case, async: true

  alias EzagentPluginLoom.Span

  describe "normalize/1" do
    test "passes a well-formed span through (re-normalized), readable = text" do
      raw = ~s(<span type="services">{"type":"services","text":"给你几个服务","items":[]}</span>)
      {span, readable} = Span.normalize(raw)
      assert span =~ ~s(<span type="services">)
      assert span =~ ~s("type":"services")
      assert readable == "给你几个服务"
    end

    test "bare JSON object → wrapped span; type inferred when absent" do
      {span, _} = Span.normalize(~s({"text":"匹配到这些","items":[{"name":"未名智引","fit":91}]}))
      assert span =~ ~s(<span type="companies">)
    end

    test "items without fit → services" do
      {span, _} = Span.normalize(~s({"text":"服务","items":[{"name":"政策对接"}]}))
      assert span =~ ~s(<span type="services">)
    end

    test "garbage with no JSON → text fallback, readable = the raw text" do
      {span, readable} = Span.normalize("这就是一句普通话")
      assert span =~ ~s(<span type="text">)
      assert readable == "这就是一句普通话"
    end

    test "empty input → text card with placeholder" do
      {span, readable} = Span.normalize("")
      assert span =~ ~s(<span type="text">)
      assert readable == "（无内容）"
    end
  end

  describe "infer_type/1" do
    test "field-shape inference" do
      assert Span.infer_type(%{"fields" => []}) == "form"
      assert Span.infer_type(%{"steps" => []}) == "steps"
      assert Span.infer_type(%{"facts" => []}) == "detail"
      assert Span.infer_type(%{"sections" => %{}, "company" => "x"}) == "intent"
      assert Span.infer_type(%{"sections" => %{}}) == "application"
      assert Span.infer_type(%{"options" => []}) == "choices"
      assert Span.infer_type(%{"tone" => "warn"}) == "notice"
      assert Span.infer_type(%{"text" => "hi"}) == "text"
    end

    test "explicit known type wins" do
      assert Span.infer_type(%{"type" => "detail", "fields" => []}) == "detail"
    end
  end

  describe "extract_first_json_object/1" do
    test "skips leading prose + code fence, returns first balanced object" do
      raw = "好的,这是结果:\n```json\n{\"type\":\"text\",\"text\":\"hi\"}\n```"
      assert Span.extract_first_json_object(raw) == ~s({"type":"text","text":"hi"})
    end

    test "nil when no object" do
      assert Span.extract_first_json_object("no braces here") == nil
    end
  end
end
