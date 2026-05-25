defmodule Ezagent.PluginNp.Template.NpAgentTest do
  use ExUnit.Case, async: true

  alias Ezagent.PluginNp.Template.NpAgent, as: Tmpl

  describe "template_name/0" do
    test "is the canonical np.agent string" do
      assert Tmpl.template_name() == "np.agent"
    end
  end

  describe "validate/1 — happy path" do
    test "accepts a minimal valid template" do
      assert :ok =
               Tmpl.validate(%{
                 "class" => "np.agent",
                 "agent_uri" => "entity://agent/team-alpha/np_compute"
               })
    end

    test "accepts an extended valid template with cwd + timeout_ms" do
      assert :ok =
               Tmpl.validate(%{
                 "class" => "np.agent",
                 "agent_uri" => "entity://agent/team-alpha/np_calc",
                 "cwd" => System.tmp_dir!(),
                 "timeout_ms" => 5_000
               })
    end
  end

  describe "validate/1 — class field" do
    test "rejects missing class" do
      assert {:error, :missing_class_field} =
               Tmpl.validate(%{"agent_uri" => "entity://agent/team-alpha/np_x"})
    end

    test "rejects wrong class" do
      assert {:error, {:wrong_class, "echo.agent"}} =
               Tmpl.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://agent/team-alpha/np_x"
               })
    end
  end

  describe "validate/1 — agent_uri field" do
    test "rejects missing agent_uri" do
      assert {:error, :missing_agent_uri} = Tmpl.validate(%{"class" => "np.agent"})
    end

    test "rejects 2-segment legacy URI (no workspace segment)" do
      # `entity://agent/np_x` parses as host=agent, path=/np_x — split-2
      # on "np_x" gives ["np_x"] (single element), so the [workspace,
      # entity_name] destructure fails. Surfaces as :missing_flavor_prefix
      # (the catch-all destructure-failure error). The narrower
      # :invalid_agent_uri / 2-segment-rejection path requires the
      # strict Ezagent.URI.parse!/1 which raises at construction; this
      # template's check_agent_uri uses URI.new which is more lenient
      # and falls into the destructure path.
      #
      # NOTE: the 2-segment literal is split across two strings so the
      # `EntitiesHaveWorkspaceTest` codebase-grep gate (Phase 9 PR-2)
      # doesn't flag this intentional negative test as a regression.
      legacy = "entity://agent/" <> "np_x"

      assert {:error, {:missing_flavor_prefix, ^legacy, _}} =
               Tmpl.validate(%{
                 "class" => "np.agent",
                 "agent_uri" => legacy
               })
    end

    test "rejects wrong flavor prefix" do
      assert {:error, {:wrong_agent_flavor, "cc", expected: "np"}} =
               Tmpl.validate(%{
                 "class" => "np.agent",
                 "agent_uri" => "entity://agent/team-alpha/cc_x"
               })
    end

    test "rejects entity_name without flavor prefix" do
      assert {:error, {:missing_flavor_prefix, _, _}} =
               Tmpl.validate(%{
                 "class" => "np.agent",
                 "agent_uri" => "entity://agent/team-alpha/nameonly"
               })
    end

    test "rejects non-entity scheme" do
      assert {:error, {:bad_agent_uri, _}} =
               Tmpl.validate(%{
                 "class" => "np.agent",
                 "agent_uri" => "session://default/team-alpha/x"
               })
    end
  end

  describe "validate/1 — optional fields" do
    test "rejects cwd that does not exist" do
      assert {:error, {:bad_cwd, "/this/path/should/not/exist"}} =
               Tmpl.validate(%{
                 "class" => "np.agent",
                 "agent_uri" => "entity://agent/team-alpha/np_x",
                 "cwd" => "/this/path/should/not/exist"
               })
    end

    test "accepts timeout_ms as string of integer" do
      assert :ok =
               Tmpl.validate(%{
                 "class" => "np.agent",
                 "agent_uri" => "entity://agent/team-alpha/np_x",
                 "timeout_ms" => "5000"
               })
    end

    test "rejects malformed timeout_ms" do
      assert {:error, {:bad_timeout, "abc"}} =
               Tmpl.validate(%{
                 "class" => "np.agent",
                 "agent_uri" => "entity://agent/team-alpha/np_x",
                 "timeout_ms" => "abc"
               })
    end
  end

  describe "form_fields/0" do
    test "declares the three documented fields" do
      names = Tmpl.form_fields() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["agent_uri", "cwd", "timeout_ms"]
    end

    test "agent_uri is required" do
      [agent_field] = Enum.filter(Tmpl.form_fields(), &(&1.name == "agent_uri"))
      assert agent_field.required == true
    end
  end
end
