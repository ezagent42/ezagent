defmodule Ezagent.CapabilityColdNodeActionTest do
  use ExUnit.Case, async: true

  alias Ezagent.Capability

  # #189 COLD-NODE cap-widening — the UPSTREAM PRODUCER (this PR), distinct from
  # the missing-key GUARDS #1654 (`fill_defaults`, write side) / #1656
  # (`from_map`, read side).
  #
  # ROOT CAUSE (proven live on the stable node, 2026-07-31): the identity cutover
  # runs `Ezagent.Identity.Backfill.run/1` on a `bin/ezagent eval` node that only
  # started `:ezagent_domain_identity` + deps (`EzagentCore.Release.identity_cutover/1`).
  # `Backfill` decodes `users.caps_json` via `Ezagent.Capability.from_map/1`
  # (`Users.list_all/0` → `UserStore.decode_caps`). `from_map/1` resolves the
  # `"action"` STRING with `string_to_atom_or_module/1`, which pre-fix used
  # `String.to_existing_atom/1` + `rescue -> :any`. The action atom `:create_session`
  # is defined by the Workspace Kind (`:ezagent_domain_workspace`, NOT a dep of
  # identity), so on the partial eval node that atom is ABSENT from the table:
  # `to_existing_atom` raised and the rescue SILENTLY WIDENED `:create_session` →
  # `:any` (workspace-admin) while the signature was preserved verbatim — the
  # `{:caps_mismatch}` the fleet-parity barrier caught.
  #
  # THE KEY DISTINCTION FROM #1654/#1656: the `"action"` KEY is PRESENT the whole
  # time (raw JSON = `"action" => "create_session"` on both planes). The missing-key
  # guards never fire — the widening is a RESOLUTION failure, not a missing key.
  #
  # This suite reproduces the cold-node condition IN ISOLATION with a well-formed
  # action name whose atom has NEVER been loaded into this VM (a unique runtime
  # suffix) — i.e. an atom absent from the table, exactly as `:create_session` is
  # absent on the eval node. It must FAIL on origin/main (decodes to `:any`) and
  # PASS with the fix (decodes to the concrete action).

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

  describe "#189 cold-node producer — from_map/1 must preserve a PRESENT action whose atom is not loaded" do
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

    test "legacy tolerance preserved: an UNSIGNED map missing the action KEY still decodes to :any" do
      # The pre-action-axis round-trip (a genuinely legacy, UNSIGNED cap with no
      # action key) is UNCHANGED by this fix — the missing-KEY path is orthogonal
      # to the present-but-unresolvable path fixed here (and is what #1656 hardens
      # for the SIGNED case).
      legacy_unsigned =
        %{
          "kind" => "any",
          "behavior" => "any",
          "instance" => "any",
          "workspace_uri" => "any",
          "granted_by" => "plugin_declared",
          "granted_at" => "2026-07-31T00:00:00.000000Z"
        }

      cap = Capability.from_map(legacy_unsigned)
      assert cap.action == :any
      assert cap.signature == nil
    end
  end
end
