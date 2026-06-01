defmodule Ezagent.Routing.PromptTemplateTest do
  use ExUnit.Case, async: true
  alias Ezagent.Routing.PromptTemplate
  doctest Ezagent.Routing.PromptTemplate

  describe "validate/1" do
    test "ok when {body} present" do
      assert :ok = PromptTemplate.validate("you are in a game: {body}")
    end

    test "error when {body} missing" do
      assert {:error, :body_placeholder_required} =
               PromptTemplate.validate("no body here {sender}")
    end

    test "error for non-string" do
      assert {:error, :not_a_string} = PromptTemplate.validate(nil)
    end
  end

  describe "render/2" do
    test "substitutes known vars (single pass, stringifies)" do
      out =
        PromptTemplate.render("hi {sender} / {body} / {sent_at}", %{
          sender: "alice",
          body: "yo",
          sent_at: 42
        })

      assert out == "hi alice / yo / 42"
    end

    test "stringifies a %URI{} sender" do
      out =
        PromptTemplate.render("from {sender}: {body}", %{
          sender: URI.new!("entity://user/system/admin"),
          body: "hi"
        })

      assert out == "from entity://user/system/admin: hi"
    end

    test "leaves unknown placeholders untouched + nil → empty" do
      out = PromptTemplate.render("{body} {unknown} {flavor}", %{body: "x", flavor: nil})
      assert out == "x {unknown} "
    end

    test "the telephone_hop template example renders + validates" do
      tmpl = "你在玩传话接龙。目前内容：\n{body}\n请只追加一句简短的话。"
      assert :ok = PromptTemplate.validate(tmpl)
      assert PromptTemplate.render(tmpl, %{body: "山顶的雪化了"}) =~ "山顶的雪化了"
    end
  end

  test "allowed_vars/0 lists the fixed v1 set" do
    assert PromptTemplate.allowed_vars() == [:sender, :flavor, :body, :session, :sent_at]
  end
end
