defmodule Ezagent.Socialware.DefinitionEditorAuthoredPinTest do
  # SECURITY (codex BLOCKER) — a user-authored SessionTemplate must NEVER carry a
  # pinned `config_id`/`content_hash` in its `installs`. A pin is ONLY ever
  # legitimately baked by the AUTHORIZED `World.SocialwareInstall` flow, which
  # resolves through the scope-gated
  # `DefinitionRegistry.resolve_installable_revision/3`. If a user could smuggle a
  # `config_id` through the template-author boundary
  # (`DefinitionEditor.composition_template_content/4`), session materialization
  # would resolve that pin via a raw `ConfigStore.fetch_object/1` with NO
  # installable-scope gate — installing a PRIVATE foreign-workspace def by id.
  #
  # An authored install is a BARE-NAME `ref` only; the system sets `config_id`
  # via the authorized freeze. So the author boundary REJECTS any user-supplied
  # install entry carrying a `config_id` or `content_hash`.
  use ExUnit.Case, async: true

  alias Ezagent.Socialware.DefinitionEditor

  @workspace Ezagent.URI.new!("workspace://authored-pin-consumer")

  describe "composition_template_content/4 — author boundary rejects smuggled pins" do
    test "REJECTS a user-supplied installs entry carrying a foreign config_id" do
      params = %{
        "description" => "smuggle attempt",
        "installs" => [
          %{"ref" => "victim", "config_id" => "foreign-private-revision-id"}
        ]
      }

      assert {:error, {:socialware_authored_pin_forbidden, _}} =
               DefinitionEditor.composition_template_content(params, nil, @workspace, nil)
    end

    test "REJECTS a user-supplied installs entry carrying a content_hash" do
      params = %{
        "installs" => [%{"ref" => "victim", "content_hash" => "deadbeef"}]
      }

      assert {:error, {:socialware_authored_pin_forbidden, _}} =
               DefinitionEditor.composition_template_content(params, nil, @workspace, nil)
    end

    test "REJECTS even when an atom-keyed config_id is supplied" do
      params = %{installs: [%{ref: "victim", config_id: "foreign-private-revision-id"}]}

      assert {:error, {:socialware_authored_pin_forbidden, _}} =
               DefinitionEditor.composition_template_content(params, nil, @workspace, nil)
    end

    test "ALLOWS a bare-name string install (the only legitimate authored shape)" do
      params = %{"description" => "ok", "installs" => ["chat", "kanban"]}

      assert {:ok, content} =
               DefinitionEditor.composition_template_content(params, nil, @workspace, nil)

      assert content.installs == ["chat", "kanban"]
    end

    test "ALLOWS a bare-name map install (ref only, no pin)" do
      params = %{"installs" => [%{"ref" => "chat"}]}

      assert {:ok, content} =
               DefinitionEditor.composition_template_content(params, nil, @workspace, nil)

      assert content.installs == [%{"ref" => "chat"}]
    end

    test "when an install_ref is given, uses the bare ref regardless of params installs" do
      params = %{"installs" => [%{"ref" => "victim", "config_id" => "foreign"}]}

      assert {:ok, content} =
               DefinitionEditor.composition_template_content(params, nil, @workspace, "my-sw")

      assert content.installs == ["my-sw"]
    end

    test "defaults to chat when no installs are supplied" do
      assert {:ok, content} =
               DefinitionEditor.composition_template_content(%{}, nil, @workspace, nil)

      assert content.installs == ["chat"]
    end
  end
end
