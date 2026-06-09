defmodule Ezagent.Kind.TemplateSharedValidatorsTest do
  @moduledoc """
  Cleanup-2 dedup: `check_agent_uri/1` and `content_field/2` were
  copy-pasted byte-identical across every flavor Template Class
  (cc / codex / curl / echo / np). They now live once in core; these
  tests pin the behavior the flavor delegations rely on.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Kind.Template

  describe "check_agent_uri/1" do
    test "accepts a well-formed entity-agent URI" do
      uri = "entity://acme/agent/cc_alice"
      assert :ok = Template.check_agent_uri(%{"agent_uri" => uri})
    end

    test "rejects an entity URI that is not an agent type" do
      uri = "entity://acme/user/alice"

      assert {:error, {:invalid_agent_uri, ^uri, _msg}} =
               Template.check_agent_uri(%{"agent_uri" => uri})
    end

    test "rejects a non-entity-scheme URI" do
      uri = "session://acme/session/s1"

      assert {:error, {:invalid_agent_uri, ^uri, _msg}} =
               Template.check_agent_uri(%{"agent_uri" => uri})
    end

    test "rejects an unparseable URI string" do
      uri = "not a uri at all !!!"
      assert {:error, {:bad_agent_uri, ^uri}} = Template.check_agent_uri(%{"agent_uri" => uri})
    end

    test "rejects a missing agent_uri key" do
      assert {:error, :missing_agent_uri} = Template.check_agent_uri(%{"class" => "cc.agent"})
    end

    test "rejects an empty agent_uri string" do
      assert {:error, :missing_agent_uri} = Template.check_agent_uri(%{"agent_uri" => ""})
    end

    test "rejects a non-binary agent_uri value" do
      assert {:error, :missing_agent_uri} = Template.check_agent_uri(%{"agent_uri" => 123})
    end
  end

  describe "content_field/2" do
    test "reads an atom key when content has atom keys (fresh)" do
      assert "cc" == Template.content_field(%{flavor: "cc"}, :flavor)
    end

    test "falls back to the string key when content has string keys (post-JSON)" do
      assert "cc" == Template.content_field(%{"flavor" => "cc"}, :flavor)
    end

    test "prefers the atom key over the string key when both present" do
      assert "atom" == Template.content_field(%{"flavor" => "string", :flavor => "atom"}, :flavor)
    end

    test "returns nil when neither key is present" do
      assert nil == Template.content_field(%{}, :flavor)
    end
  end
end
