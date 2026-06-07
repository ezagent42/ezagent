defmodule Ezagent.Socialware.ConfigProjectionTest do
  @moduledoc """
  #607 codex MEDIUM — the `resource://` outer workspace segment must be
  AUTHORITATIVE. `resolve_config_dir/1` decodes the immutable config OBJECT's id
  from the base64 `<name>` payload and loads the object; if the object's own
  `workspace_uri` is trusted WITHOUT checking it against the URI's STRUCTURAL
  `<workspace>` segment, an authorable `resource://A/...` URI naming tenant B's
  object resolves B's soul from inside A — a cross-tenant boundary hole. These
  tests pin a LOUD rejection of any such mismatch.

  #607 codex round-2 CRITICAL — the layer URI is OBJECT-keyed (names a specific
  immutable `ConfigObject` by id), not pointer-keyed.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.Socialware.{ConfigProjection, ConfigStore}

  @key "advisor.behavior"

  defp workspace(name), do: Ezagent.URI.workspace(name)

  defp agent(ws_name),
    do: Ezagent.URI.agent(ws_name, "adv-#{System.unique_integer([:positive])}")

  describe "object_id_from_uri/1" do
    test "a well-formed object URI round-trips to the object id" do
      ws = workspace(:team_alpha)
      object_id = Ecto.UUID.generate()
      uri = ConfigProjection.object_uri(ws, object_id)

      assert {:ok, ^object_id} = ConfigProjection.object_id_from_uri(uri)
    end

    test "a non-socialware resource URI is :error (not mine)" do
      other = Ezagent.URI.resource("team_alpha", "credential-src", "cc")
      assert :error = ConfigProjection.object_id_from_uri(other)
    end
  end

  describe "resolve_config_dir/1 workspace-segment authority" do
    test "a well-formed object URI resolves its immutable object's soul" do
      ws = workspace(:team_alpha)
      subject = agent(:team_alpha)

      {:ok, object} =
        ConfigStore.write_config(%{
          workspace_uri: ws,
          subject_uri: subject,
          key: @key,
          body: %{"tone" => "neutral"},
          actor_uri: User.admin_uri(),
          source_turn_id: "seed"
        })

      uri = ConfigProjection.object_uri(ws, object.id)
      assert {:ok, dir} = ConfigProjection.resolve_config_dir(uri)
      assert File.read!(Path.join(dir, "CLAUDE.md")) =~ "neutral"
      File.rm_rf(dir)
    end

    test "a cross-tenant forged URI never resolves the victim's object" do
      victim_ws = workspace(:team_alpha)
      subject = agent(:team_alpha)

      {:ok, object} =
        ConfigStore.write_config(%{
          workspace_uri: victim_ws,
          subject_uri: subject,
          key: @key,
          body: %{"secret" => "victim-soul"},
          actor_uri: User.admin_uri(),
          source_turn_id: "seed"
        })

      # Author a URI whose STRUCTURAL workspace segment is team_beta but whose
      # encoded object id is the victim's (team_alpha) object.
      forged = forge_cross_tenant_uri("team_beta", object.id)

      assert_raise ArgumentError, ~r/workspace/i, fn ->
        ConfigProjection.resolve_config_dir(forged)
      end
    end

    test "a well-formed URI naming a non-existent object fails loud" do
      ws = workspace(:team_alpha)
      uri = ConfigProjection.object_uri(ws, Ecto.UUID.generate())

      assert {:error, {:socialware_config_object_not_found, _}} =
               ConfigProjection.resolve_config_dir(uri)
    end
  end

  # Build a `resource://<structural_ws>/socialware-config-object/<base64(object_id)>`
  # URI where the structural segment differs from the object's own workspace —
  # the exact cross-tenant attack the authority check must reject.
  defp forge_cross_tenant_uri(structural_ws, object_id) do
    name = Base.url_encode64(object_id, padding: false)
    Ezagent.URI.resource(structural_ws, ConfigProjection.type_segment(), name)
  end
end
