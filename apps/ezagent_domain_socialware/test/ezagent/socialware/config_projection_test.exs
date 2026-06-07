defmodule Ezagent.Socialware.ConfigProjectionTest do
  @moduledoc """
  #607 codex MEDIUM — the `resource://` outer workspace segment must be
  AUTHORITATIVE. `pointer_key_from_uri/1` / `resolve_config_dir/1` decode the
  `{layer, workspace, subject, key}` from the base64 `<name>` payload; if the
  decoded `workspace` is trusted WITHOUT checking it against the URI's
  STRUCTURAL `<workspace>` segment, an authorable `resource://A/...` URI whose
  payload encodes workspace B resolves B's pointer — a cross-tenant boundary
  hole. These tests pin a LOUD rejection of any such mismatch.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.Socialware.{ConfigProjection, ConfigStore}

  @key "advisor.behavior"

  defp workspace(name), do: Ezagent.URI.workspace(name)

  defp agent(ws_name),
    do: Ezagent.URI.agent(ws_name, "adv-#{System.unique_integer([:positive])}")

  describe "pointer_key_from_uri/1 workspace-segment authority" do
    test "a well-formed pointer URI round-trips" do
      ws = workspace(:team_alpha)
      subject = agent(:team_alpha)
      uri = ConfigProjection.pointer_uri(:user, ws, subject, @key)

      assert {:ok, {"user", _ws, _subject, @key}} = ConfigProjection.pointer_key_from_uri(uri)
    end

    test "raises LOUDLY when the structural workspace segment != the encoded workspace" do
      # Author a URI in workspace `team_beta` (structural segment) but whose
      # base64 payload encodes workspace `team_alpha` (the victim tenant).
      victim_ws = workspace(:team_alpha)
      subject = agent(:team_alpha)
      forged = forge_cross_tenant_uri("team_beta", :user, victim_ws, subject, @key)

      assert_raise ArgumentError, ~r/workspace/i, fn ->
        ConfigProjection.pointer_key_from_uri(forged)
      end
    end
  end

  describe "resolve_config_dir/1 workspace-segment authority" do
    test "a cross-tenant forged URI never resolves the victim's pointer" do
      victim_ws = workspace(:team_alpha)
      subject = agent(:team_alpha)

      {:ok, _} =
        ConfigStore.write_and_point(%{
          layer: :user,
          workspace_uri: victim_ws,
          subject_uri: subject,
          key: @key,
          body: %{"secret" => "victim-soul"},
          actor_uri: User.admin_uri(),
          source_turn_id: "seed"
        })

      forged = forge_cross_tenant_uri("team_beta", :user, victim_ws, subject, @key)

      assert_raise ArgumentError, ~r/workspace/i, fn ->
        ConfigProjection.resolve_config_dir(forged)
      end
    end
  end

  # Build a `resource://<structural_ws>/socialware-config/<base64(...)>` URI
  # where the base64 payload encodes a DIFFERENT workspace than the structural
  # segment — the exact cross-tenant attack the authority check must reject.
  defp forge_cross_tenant_uri(structural_ws, layer, encoded_ws, subject, key) do
    pointer_id =
      Ezagent.Socialware.ConfigPointer.id(
        Atom.to_string(layer),
        URI.to_string(encoded_ws),
        URI.to_string(subject),
        key
      )

    name = Base.url_encode64(pointer_id, padding: false)
    Ezagent.URI.resource(structural_ws, ConfigProjection.type_segment(), name)
  end
end
