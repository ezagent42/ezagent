defmodule Ezagent.UI.FormTest do
  @moduledoc """
  Phase 5 PR 2 invariant — every registered Template Class that
  implements Ezagent.UI.Form lists at least one field, and the default
  form_to_args/2 produces a map containing the Class's template_name
  under "class".

  If this test breaks, the dynamic add-template form will mis-render
  or fail to translate operator input to template_data.
  """
  use ExUnit.Case

  alias Ezagent.UI.Form

  describe "implements?/1" do
    test "true for Template Classes that opted in" do
      assert Form.implements?(Ezagent.PluginCc.Template.CcAgent)
      assert Form.implements?(Ezagent.Template.GenericSession)
    end

    test "false for arbitrary modules" do
      refute Form.implements?(Ezagent.Home)
    end
  end

  describe "default_form_to_args/2" do
    test "adds class field from template_name/0" do
      out =
        Form.default_form_to_args(Ezagent.PluginCc.Template.CcAgent, %{
          "agent_uri" => "entity://team-alpha/agent/cc_x"
        })

      assert out["class"] == "cc.agent"
      assert out["agent_uri"] == "entity://team-alpha/agent/cc_x"
    end
  end

  describe "list_form_classes/0" do
    test "returns all registered Classes implementing Ezagent.UI.Form sorted by name" do
      classes = Form.list_form_classes()
      names = Enum.map(classes, fn {n, _, _} -> n end)

      assert "cc.agent" in names
      assert "session.generic" in names
      assert names == Enum.sort(names)

      Enum.each(classes, fn {_name, _module, fields} ->
        assert is_list(fields)
        assert length(fields) > 0

        Enum.each(fields, fn f ->
          assert Map.has_key?(f, :name)
          assert Map.has_key?(f, :type)
          assert Map.has_key?(f, :label)
          assert f.type in [:text, :path, :uri, :select]
        end)
      end)
    end
  end

  describe "form_to_args integration — GenericSession" do
    test "CSV members parsed into list, class added" do
      out =
        Ezagent.Template.GenericSession.form_to_args(%{
          "session_name" => "foo",
          "members_csv" => "entity://system/user/admin, entity://team-alpha/agent/test_x ,"
        })

      assert out == %{
               "class" => "session.generic",
               "session_name" => "foo",
               "members" => ["entity://system/user/admin", "entity://team-alpha/agent/test_x"]
             }
    end
  end
end
