defmodule Ezagent.CapabilityColdNodeActionTest do
  use ExUnit.Case, async: true

  alias Ezagent.Capability

  # A well-formed action string may be decoded before its atom has otherwise been
  # loaded in this VM. Resolution failure must never widen that concrete action to
  # the privileged `:any` wildcard while preserving the artifact signature.

  # A JSON-decoded (string-keyed), SIGNED workspace cap map, minus the action —
  # which the caller supplies. URI-registry-free (`granted_by: "plugin_declared"`,
  # all axes `"any"`) so ONLY the action-atom resolution is under test.
  defp signed_cap_json(action_string) do
    %{
      "kind" => "any",
      "behavior" => "any",
      "action" => action_string,
      "instance" => "any",
      "workspace_uri" => "any",
      "granted_by" => "plugin_declared",
      "granted_at" => "2026-07-31T00:00:00.000000Z",
      "signature" => Base.url_encode64("cold-node-signature-bytes", padding: false),
      "key_id" => "k1",
      "grantee_uri" => nil
    }
  end

  describe "from_map/1 preserves a present action whose atom is not loaded" do
    test "a well-formed action string whose atom is absent round-trips to the concrete atom, NOT :any" do
      # Never referenced anywhere → guaranteed absent from the atom table until
      # `from_map/1` resolves it. This is the cold node's `:create_session` in
      # miniature: a valid action name the decoding node has never loaded.
      action_string = "cold_action_#{System.unique_integer([:positive])}"

      cap = Capability.from_map(signed_cap_json(action_string))

      # Fail-before (origin/main): `to_existing_atom` raises → rescue → `:any`, so
      # `Atom.to_string(:any) == "any" != action_string`. Pass-after: `to_atom`
      # yields the concrete atom whose name is exactly `action_string`.
      assert Atom.to_string(cap.action) == action_string,
             "a valid action name whose atom is not yet loaded on the decoding node " <>
               "must round-trip to its concrete atom, not be silently widened to :any " <>
               "(got #{inspect(cap.action)})"

      refute cap.action == :any,
             "the cold-node decode must NOT widen a concrete signed action to the :any " <>
               "workspace-admin wildcard (the #189 identity-plane divergence)"

      # The signature is preserved verbatim through the decode (the exact
      # "same signature, action silently widened" divergence shape).
      assert cap.signature == "cold-node-signature-bytes"
    end

    test "control: an action whose atom IS loaded decodes to that atom on any node" do
      # `:known_loaded_action` is created at COMPILE time by this literal, so its
      # atom always exists — mirrors the WARM node where `:create_session` is
      # loaded. Never affected by the bug; asserts the fix is a no-regression for
      # the common (loaded) case.
      _ = :known_loaded_action
      cap = Capability.from_map(signed_cap_json("known_loaded_action"))
      assert cap.action == :known_loaded_action
    end

    test "an unsigned map missing the action key is rejected" do
      unsigned_incomplete =
        %{
          "kind" => "any",
          "behavior" => "any",
          "instance" => "any",
          "workspace_uri" => "any",
          "granted_by" => "plugin_declared",
          "granted_at" => "2026-07-31T00:00:00.000000Z"
        }

      assert_raise KeyError, fn -> Capability.from_map(unsigned_incomplete) end
    end
  end
end
