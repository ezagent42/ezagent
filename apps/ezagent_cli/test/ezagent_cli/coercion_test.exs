defmodule EzagentCli.CoercionTest do
  use ExUnit.Case, async: true

  alias EzagentCli.Coercion

  describe "to_option/2 for primitive types" do
    test ":string maps to identity parser" do
      assert {:foo, kw} = Coercion.to_option(:foo, :string)
      assert Keyword.get(kw, :long) == "foo"
      assert Keyword.get(kw, :parser) == :string
    end

    test ":integer uses Optimus built-in parser" do
      assert {:n, kw} = Coercion.to_option(:n, :integer)
      assert Keyword.get(kw, :parser) == :integer
    end

    test ":uri parser converts valid URI strings" do
      {_, kw} = Coercion.to_option(:member, :uri)
      parser = Keyword.fetch!(kw, :parser)

      assert {:ok, %URI{scheme: "entity", host: "agent", path: "/team-alpha/test_cc-architect"}} =
               parser.("entity://agent/team-alpha/test_cc-architect")
    end

    test ":uri parser rejects malformed" do
      {_, kw} = Coercion.to_option(:member, :uri)
      parser = Keyword.fetch!(kw, :parser)
      assert {:error, _} = parser.("not-a-uri")
    end

    test ":map parser decodes JSON" do
      {_, kw} = Coercion.to_option(:template, :map)
      parser = Keyword.fetch!(kw, :parser)
      assert {:ok, %{"a" => 1}} = parser.(~s({"a":1}))
    end

    test ":map parser rejects non-object JSON" do
      {_, kw} = Coercion.to_option(:template, :map)
      parser = Keyword.fetch!(kw, :parser)
      assert {:error, _} = parser.(~s([1, 2]))
    end

    test ":atom parser refuses unknown atoms (security)" do
      {_, kw} = Coercion.to_option(:flavor, :atom)
      parser = Keyword.fetch!(kw, :parser)
      assert {:error, _} = parser.("definitely_unknown_#{System.unique_integer()}")
    end
  end

  describe "to_option for list types" do
    test "{:list, :uri} via CSV" do
      {_, kw} = Coercion.to_option(:members, {:list, :uri})
      parser = Keyword.fetch!(kw, :parser)

      assert {:ok, [%URI{}, %URI{}]} = parser.("entity://user/system/admin,entity://agent/team-alpha/test_x")
    end

    test "{:list, :string} via CSV" do
      {_, kw} = Coercion.to_option(:tags, {:list, :string})
      parser = Keyword.fetch!(kw, :parser)
      assert {:ok, ["a", "b", "c"]} = parser.("a,b,c")
    end
  end

  describe "to_option for {:option, T}" do
    test "wraps T as not-required" do
      {_, kw} = Coercion.to_option(:opt, {:option, :string})
      assert Keyword.get(kw, :required) == false
    end
  end

  describe "flag?/1" do
    test "true for :boolean" do
      assert Coercion.flag?(:boolean)
    end

    test "false for other types" do
      refute Coercion.flag?(:string)
      refute Coercion.flag?(:uri)
      refute Coercion.flag?({:list, :uri})
    end
  end
end
