defmodule Ezagent.Capability.Normalize do
  @moduledoc false

  alias Ezagent.Capability
  alias Ezagent.Capability.Match

  @doc """
  Serialize a `%Capability{}` to a JSON-safe STRING-keyed map for
  `users.caps_json` storage: atoms/modules → strings, URIs → strings, `:any`
  → `"any"`, `granted_at` → ISO8601. Inverse of `from_map/1`. Backs
  `Ezagent.Capability.to_map/1`.

  ## Legacy-shape tolerance (#213 — canary cutover-backfill catch #2)

  Routes the cap through `fill_defaults/1` first, which re-projects it onto a
  fresh defstruct so fields added AFTER it was serialized are present with their
  `nil` defaults. A durable Kind's `:identity` slice snapshotted before the
  #1399 cap-signing trio (`signature` / `key_id` / `grantee_uri`, 2026-07-14)
  stores a `%Capability{}` via `:erlang.term_to_binary/1`; `binary_to_term`
  reconstructs it as a struct-shaped map that MATCHES `%Capability{}` (struct
  matching only checks `:__struct__`) yet LACKS the trio's keys — so a strict
  `cap.signature` field access raised `(KeyError) key :signature not found`,
  crashing the cutover backfill's `encode_caps/1`
  (`EzagentCore.Release.identity_cutover/1` Step 1/3). Re-projection fills the
  missing keys so serialization is total. It NEVER widens an authorization axis:
  a genuinely-absent `workspace_uri` fills with `nil` and fails LOUD in
  `workspace_to_wire/1` — it is not smoothed to `:any`. A legacy unsigned cap
  serializes with `"signature" => nil` (still non-licensing: the self-license
  verify fails closed on a non-binary signature).

  A non-`%Capability{}` input is a bug (every serialize-path cap is a struct —
  users decode via `from_map/1`, snapshots via `binary_to_term`); it is left to
  crash rather than silently coerced, since `from_map/1` would default a missing
  `workspace_uri` to `:any` (cross-workspace).
  """
  @spec to_map(Capability.t()) :: map()
  def to_map(%Capability{} = cap) do
    cap = fill_defaults(cap)

    %{
      "kind" => atom_or_module_to_string(cap.kind),
      "behavior" => atom_or_module_to_string(cap.behavior),
      "action" => atom_or_module_to_string(Match.action_of(cap)),
      "instance" => instance_to_wire(cap.instance),
      "workspace_uri" => workspace_to_wire(cap.workspace_uri),
      "granted_by" => granted_by_to_wire(cap.granted_by),
      "granted_at" => DateTime.to_iso8601(cap.granted_at),
      "signature" => encode_signature(cap.signature),
      "key_id" => cap.key_id,
      "grantee_uri" => uri_or_nil_to_string(cap.grantee_uri),
      "signing_version" => cap.signing_version,
      "grant_id" => cap.grant_id
    }
  end

  @doc """
  Re-project a `%Capability{}` onto a fresh defstruct so every CURRENT field is
  present, filling fields added after the struct was serialized (the #1399
  cap-signing trio `signature` / `key_id` / `grantee_uri`) with their `nil`
  defaults.

  `struct/2` starts from `%Capability{}` (all defaults) and overlays only the
  legacy map's recognized fields, so a pre-#1399 `binary_to_term`'d cap
  (struct-shaped map missing the trio's keys) becomes a complete, strict-field-
  accessible struct. It does NOT invent authorization: a missing `workspace_uri`
  fills with the `nil` defstruct default (which fails LOUD at serialize time),
  never `:any`; and `@enforce_keys` legacy fields (kind/behavior/instance/
  workspace_uri/granted_by/granted_at, all pre-#1399) are already present.

  Shared by `to_map/1` and the `Jason.Encoder` impl so the two serializers
  cannot drift on legacy-shape tolerance.

  ## Fail-CLOSED on a signed cap that lost its `:action` axis (#189 divergence)

  `struct/2` fills a MISSING `:action` KEY with the defstruct default `:any`
  (workspace-admin). For a `binary_to_term`'d / mis-shaped struct-map that lacks
  the key that is a SILENT PRIVILEGE ESCALATION: the cap's SIGNATURE still covers
  its true concrete action (e.g. `:create_session`), so the widened `:any` copy
  is a signature-INVALID artifact that nonetheless serializes into the
  identity-caps store as workspace-admin — the exact `{:caps_mismatch}` the #189
  fleet-parity barrier caught (`create_session` in `users.caps_json`, `any` in
  the store mirror, SAME signature). The capability-action-axis (SPEC 2026-05-27)
  predates the #1399 cap-signing trio (2026-07-14), so ANY cap carrying a
  `signature` was minted WITH the action axis and MUST carry a concrete
  `:action`; a signed cap whose `:action` key is absent is therefore corruption,
  never legacy, and is REFUSED here (the same fail-LOUD contract this helper
  already honors for a missing `workspace_uri`). A genuinely pre-action-axis cap
  is UNSIGNED (pre-#1399), so its missing action still honestly reprojects to
  `:any` (the #213 legacy tolerance is preserved).
  """
  @spec fill_defaults(Capability.t()) :: Capability.t()
  def fill_defaults(%Capability{} = cap) do
    refuse_signed_action_widening!(cap)
    struct(Capability, Map.from_struct(cap))
  end

  # A cap carrying a `signature` post-dates the action-axis, so a missing
  # `:action` KEY is corruption — refuse to widen it to `:any` at serialize time.
  defp refuse_signed_action_widening!(cap) do
    if not Map.has_key?(cap, :action) and not is_nil(Map.get(cap, :signature)) do
      raise ArgumentError,
            "Ezagent.Capability.Normalize: a SIGNED capability is missing its " <>
              "`:action` axis — refusing to serialize it. Reprojecting would widen the " <>
              "absent action to `:any` (workspace-admin), a SILENT privilege escalation " <>
              "whose signature still covers the true concrete action (the #189 " <>
              "identity-plane divergence). A signature post-dates the " <>
              "capability-action-axis, so a signed cap MUST carry a concrete `:action`; " <>
              "a missing one is corruption, not legacy. Got: #{inspect(cap)}"
    end

    :ok
  end

  @doc """
  Deserialize a JSON-decoded STRING-keyed map back to `%Capability{}`. This is
  the TOLERANT read-side decode (contrast the strict `normalize!/2` grant
  chokepoint): a missing `"action"`/`"workspace_uri"` KEY defaults to `:any`, so
  a row authored before the action-axis / `workspace_uri` field still round-trips.
  A PRESENT atom/module NAME is resolved via `String.to_atom/1` (create-if-absent,
  see `string_to_atom_or_module/1`), so it round-trips to its concrete value
  regardless of which modules are loaded on the decoding node — closing the #189
  cold-node silent-widening where a valid `"create_session"` collapsed to `:any`
  merely because the defining app was unstarted on a partial `bin/ezagent eval`
  cutover node. (A well-formed but genuinely unknown name becomes its own concrete
  atom, authorization-inert, never the `:any` wildcard.)
  CAUTION: because a missing `"workspace_uri"` becomes `:any` (cross-workspace),
  this decode does NOT itself reject a field-less row — the durable
  `users.caps_json` path relies on every persisted cap actually carrying the
  field (post-PR-3 grant code always writes it via `normalize!/2`). Inverse of
  `to_map/1`; backs `Ezagent.Capability.from_map/1`.

  ## Fail-CLOSED on a SIGNED map that lost its `"action"` (#189 divergence — READ side)

  The tolerant `Map.put_new("action", "any")` below silently defaults a MISSING
  `"action"` to `:any` (workspace-admin) while `decode_signature/1` decodes and
  PRESERVES the map's `"signature"` verbatim. For a JSON map that carries a
  `"signature"` but LACKS `"action"` that is a SILENT PRIVILEGE ESCALATION — the
  exact `{:caps_mismatch}` the #189 fleet-parity barrier caught (a workspace cap
  read back as `:any` with a signature that still covers the true concrete action,
  e.g. `:create_session`). This is the READ-side (deserialize) symmetric twin of
  `fill_defaults/1`'s WRITE-side (serialize) guard: the capability-action-axis
  (SPEC 2026-05-27) predates the #1399 cap-signing trio (2026-07-14), so ANY
  cap carrying a `"signature"` was minted WITH the action axis and MUST carry a
  concrete `"action"`; a signed map whose `"action"` key is absent is therefore
  corruption, never legacy, and is REFUSED here rather than round-tripped into an
  `:any` cap. A genuinely pre-action-axis cap is UNSIGNED (pre-#1399), so its
  missing action still tolerantly decodes to `:any` — the documented legacy
  round-trip tolerance is preserved.
  """
  @spec from_map(map()) :: Capability.t()
  def from_map(%{} = m) do
    refuse_signed_action_widening_on_decode!(m)
    m = Map.put_new(m, "action", "any")

    %Capability{
      kind: string_to_atom_or_module(Map.get(m, "kind")),
      behavior: string_to_atom_or_module(Map.get(m, "behavior")),
      action: string_to_atom_or_module(Map.get(m, "action")),
      instance: instance_from_wire(Map.get(m, "instance")),
      workspace_uri: workspace_from_wire(Map.get(m, "workspace_uri", "any")),
      granted_by: granted_by_from_wire(Map.get(m, "granted_by")),
      granted_at: parse_datetime(Map.get(m, "granted_at")),
      signature: decode_signature(Map.get(m, "signature")),
      key_id: Map.get(m, "key_id"),
      grantee_uri: string_to_uri_or_nil(Map.get(m, "grantee_uri")),
      signing_version: Map.get(m, "signing_version", 1),
      grant_id: Map.get(m, "grant_id")
    }
  end

  # A decoded map carrying a non-nil `"signature"` post-dates the action-axis, so
  # a missing `"action"` KEY is corruption — refuse to widen it to `:any` at
  # DECODE time (the read-side twin of `fill_defaults/1`'s write-side guard).
  # Only the SIGNED + action-less shape is refused; an unsigned legacy map still
  # tolerantly decodes a missing action to `:any` (round-trip tolerance intact).
  defp refuse_signed_action_widening_on_decode!(m) do
    if not Map.has_key?(m, "action") and not is_nil(Map.get(m, "signature")) do
      raise ArgumentError,
            "Ezagent.Capability.Normalize.from_map/1: a SIGNED capability map is " <>
              "missing its `\"action\"` field — refusing to decode it. Defaulting the " <>
              "absent action to `:any` (workspace-admin) would silently widen the true " <>
              "concrete action while preserving the (now-mismatched) signature verbatim — " <>
              "the #189 identity-plane divergence (a workspace `:create_session` cap read " <>
              "back as `:any`). A signature post-dates the capability-action-axis, so a " <>
              "signed cap MUST carry a concrete `\"action\"`; a missing one is corruption, " <>
              "not legacy. Got: #{inspect(m)}"
    end

    :ok
  end

  @doc """
  Coerce any of the three accepted grant-input shapes to a canonical
  `%Capability{}`: a `%Capability{}` (passthrough), a string-keyed
  JSON-decoded map (CLI path), or an atom-keyed Elixir map (in-VM callers) —
  stamping `granted_by`/`granted_at` when absent. The SINGLE chokepoint on
  the grant path (Bug 2, Allen 2026-05-26), per
  `feedback_let_it_crash_no_workarounds`: a missing `workspace_uri` RAISES in
  BOTH the string-keyed and atom-keyed branches (no silent cross-workspace
  default). The string-keyed (CLI/JSON) branch is strictest — a missing
  `instance` also RAISES and unknown atoms/modules RAISE (never widened to
  `:any`). The atom-keyed (in-VM Elixir) branch is laxer: it defaults a
  missing `:instance` to `:any` (`Map.get(m, :instance, :any)`), so only
  `workspace_uri` is structurally mandatory there. Backs
  `Ezagent.Capability.normalize!/2`.
  """
  @spec normalize!(Capability.t() | map(), URI.t() | String.t()) :: Capability.t()
  def normalize!(%Capability{} = cap, _granter), do: cap

  def normalize!(%{} = m, granter) when is_map_key(m, "kind") or is_map_key(m, "behavior") do
    granter_uri = parse_granter(granter)
    kind = decode_atom_or_module_strict!(m, "kind")
    behavior = decode_atom_or_module_strict!(m, "behavior")

    action =
      case Map.fetch(m, "action") do
        {:ok, _} -> decode_atom_or_module_strict!(m, "action")
        :error -> :any
      end

    workspace_uri =
      case Map.fetch(m, "workspace_uri") do
        {:ok, ws} ->
          decode_uri_or_any_strict!(ws, "workspace_uri")

        :error ->
          raise ArgumentError,
                "Ezagent.Capability.normalize!/2: string-keyed input map is missing " <>
                  "required `\"workspace_uri\"` field — per SPEC v3 §4 + " <>
                  "`feedback_let_it_crash_no_workarounds`, workspace_uri has no " <>
                  "silent default at the grant chokepoint. Pass either `\"any\"` " <>
                  "(cross-workspace) or a concrete workspace URI. " <>
                  "Got: #{inspect(m)}"
      end

    instance =
      case Map.fetch(m, "instance") do
        {:ok, i} ->
          decode_uri_or_any_strict!(i, "instance")

        :error ->
          raise ArgumentError,
                "Ezagent.Capability.normalize!/2: string-keyed input map is missing " <>
                  "required `\"instance\"` field. Pass `\"any\"` for a wildcard " <>
                  "instance or a concrete target URI. Got: #{inspect(m)}"
      end

    %Capability{
      kind: kind,
      behavior: behavior,
      action: action,
      instance: instance,
      workspace_uri: workspace_uri,
      granted_by: granter_uri,
      granted_at: DateTime.utc_now()
    }
  end

  def normalize!(%{} = m, granter) when is_map_key(m, :kind) or is_map_key(m, :behavior) do
    workspace_uri =
      case Map.fetch(m, :workspace_uri) do
        {:ok, ws} ->
          ws

        :error ->
          raise ArgumentError,
                "Ezagent.Capability.normalize!/2: atom-keyed input map is missing " <>
                  "required `:workspace_uri` field — per SPEC v3 §4 + " <>
                  "`feedback_let_it_crash_no_workarounds`, workspace_uri has no " <>
                  "silent default. Pass either `:any` (cross-workspace) or a " <>
                  "concrete `%URI{}` workspace URI. Got: #{inspect(m)}"
      end

    %Capability{
      kind: Map.get(m, :kind, :any),
      behavior: Map.get(m, :behavior, :any),
      action: Map.get(m, :action, :any),
      instance: Map.get(m, :instance, :any),
      workspace_uri: workspace_uri,
      granted_by: Map.get_lazy(m, :granted_by, fn -> parse_granter(granter) end),
      granted_at: Map.get(m, :granted_at, DateTime.utc_now())
    }
  end

  def normalize!(other, _granter) do
    raise ArgumentError,
          "Ezagent.Capability.normalize!/2: unrecognized cap shape — expected " <>
            "a `%Ezagent.Capability{}` struct, a string-keyed JSON-decoded map " <>
            "(e.g. `%{\"kind\" => \"session\", \"behavior\" => \"...\"}`), or an " <>
            "atom-keyed Elixir map (e.g. `%{kind: :session, behavior: ..., " <>
            "workspace_uri: ...}`). Got: #{inspect(other)}"
  end

  defp parse_granter(%URI{} = uri), do: uri
  defp parse_granter(s) when is_binary(s), do: Ezagent.URI.new!(s)

  defp parse_granter(other) do
    raise ArgumentError,
          "Ezagent.Capability.normalize!/2: granter must be a `%URI{}` or " <>
            "URI string. Got: #{inspect(other)}"
  end

  defp decode_atom_or_module_strict!(m, key) do
    case Map.fetch(m, key) do
      {:ok, "any"} ->
        :any

      {:ok, s} when is_binary(s) ->
        cond do
          String.starts_with?(s, "Elixir.") ->
            String.to_existing_atom(s)

          Regex.match?(~r/^[a-z_][a-z0-9_]*$/, s) ->
            String.to_existing_atom(s)

          true ->
            String.to_existing_atom("Elixir." <> s)
        end

      {:ok, other} ->
        raise ArgumentError,
              "Ezagent.Capability.normalize!/2: `\"#{key}\"` field must be a " <>
                "string (atom name like `\"session\"` or module name like " <>
                "`\"Ezagent.ActionSet.Session\"`) or `\"any\"`. Got: #{inspect(other)}"

      :error ->
        raise ArgumentError,
              "Ezagent.Capability.normalize!/2: string-keyed input map is missing " <>
                "required `\"#{key}\"` field — per `feedback_let_it_crash_no_workarounds`, " <>
                "the grant chokepoint has no silent default. Got map: #{inspect(m)}"
    end
  rescue
    e in ArgumentError ->
      case e do
        %ArgumentError{message: "Ezagent.Capability.normalize!/2:" <> _} ->
          reraise e, __STACKTRACE__

        _ ->
          raise ArgumentError,
                "Ezagent.Capability.normalize!/2: `\"#{key}\"` field references an " <>
                  "unknown atom or module — `#{inspect(Map.get(m, key))}` did not " <>
                  "resolve. Check the module is loaded / the atom is spelled " <>
                  "correctly. Per `feedback_let_it_crash_no_workarounds`, unknown " <>
                  "names are NOT silently widened to `:any`."
      end
  end

  defp decode_uri_or_any_strict!("any", _field), do: :any
  defp decode_uri_or_any_strict!(s, _field) when is_binary(s), do: Ezagent.URI.new!(s)

  defp decode_uri_or_any_strict!(other, field) do
    raise ArgumentError,
          "Ezagent.Capability.normalize!/2: `\"#{field}\"` field must be a URI " <>
            "string or `\"any\"`. Got: #{inspect(other)}"
  end

  defp atom_or_module_to_string(:any), do: "any"
  defp atom_or_module_to_string(value) when is_atom(value), do: Atom.to_string(value)

  defp string_to_atom_or_module("any"), do: :any

  # Resolve a serialized axis value (kind / behavior / action) back to its
  # concrete atom or module.
  #
  # #189 cold-node fix — use `String.to_atom/1` (create-if-absent), NOT
  # `String.to_existing_atom/1` + `rescue -> :any`. `to_existing_atom` couples
  # cap-decode correctness to the CALLING NODE'S MODULE-LOAD STATE: on a PARTIAL
  # release node (a `bin/ezagent eval` cutover node that only started
  # `:ezagent_domain_identity` + deps, per `EzagentCore.Release.identity_cutover/1`)
  # the module that defines an action atom like `:create_session` (the Workspace
  # Kind, in `:ezagent_domain_workspace`, NOT a dep of identity) is never loaded,
  # so its atom is absent from the table, `to_existing_atom` raised, and the
  # rescue SILENTLY WIDENED the concrete action to `:any` (workspace-admin) while
  # `decode_signature/1` preserved the signature verbatim — the #189 identity-plane
  # divergence (`create_session` in `users.caps_json`, `any` in the Store mirror,
  # SAME signature) that the fleet-parity barrier caught. Verified live 2026-07-31:
  # the identical `caps_json` decodes to `:create_session` via warm `rpc` (full app,
  # atom loaded) but `:any` via cold `eval` (partial app, atom absent).
  # `grant_migration.ex` already flags this same rescue-to-`:any` as a
  # silent-broadening hazard for a renamed module string.
  #
  # `to_atom` yields the SAME global atom the warm node resolves, so the decode is
  # load-state-INDEPENDENT — a valid `create_session` never collapses to `:any`
  # just because the defining app is unstarted. It is also strictly SAFER than the
  # old rescue: a genuinely unknown/defunct name now becomes its own concrete atom
  # (authorization-inert — it matches nothing) instead of the `:any` WILDCARD (which
  # matches everything). Atom-exhaustion is not a concern: every `from_map/1` caller
  # decodes OUR OWN bounded, minted cap vocabulary — durable `users.caps_json` /
  # `identity_caps` rows and the digest-bound `%Capability{}` `callback_artifact`,
  # all written by `to_map/1` — never arbitrary unbounded external input. The `cond`
  # still classifies module (`Elixir.`-prefixed / bare-capitalized) vs plain-atom
  # shape so the reconstructed atom is correct.
  defp string_to_atom_or_module(s) when is_binary(s) do
    cond do
      String.starts_with?(s, "Elixir.") ->
        String.to_atom(s)

      Regex.match?(~r/^[a-z_][a-z0-9_]*$/, s) ->
        String.to_atom(s)

      true ->
        String.to_atom("Elixir." <> s)
    end
  end

  defp instance_to_wire(:any), do: "any"
  defp instance_to_wire(%URI{} = uri), do: URI.to_string(uri)

  defp instance_to_wire({scope, %URI{} = uri})
       when scope in [:within_session, :within_workspace, :spawned_by] do
    %{"scope" => Atom.to_string(scope), "uri" => Ezagent.URI.stable_key(uri)}
  end

  defp instance_to_wire(other), do: invalid_axis!(:instance, other)

  defp workspace_to_wire(:any), do: "any"
  defp workspace_to_wire(%URI{} = uri), do: URI.to_string(uri)
  defp workspace_to_wire(other), do: invalid_axis!(:workspace_uri, other)

  defp granted_by_to_wire(%URI{} = uri), do: URI.to_string(uri)
  defp granted_by_to_wire(:plugin_declared), do: "plugin_declared"
  defp granted_by_to_wire(other), do: invalid_axis!(:granted_by, other)

  defp uri_or_nil_to_string(nil), do: nil
  defp uri_or_nil_to_string(%URI{} = uri), do: URI.to_string(uri)

  defp instance_from_wire("any"), do: :any
  defp instance_from_wire(s) when is_binary(s), do: Ezagent.URI.new!(s)

  defp instance_from_wire(%{"scope" => "within_session", "uri" => uri}),
    do: {:within_session, Ezagent.URI.new!(uri)}

  defp instance_from_wire(%{"scope" => "within_workspace", "uri" => uri}),
    do: {:within_workspace, Ezagent.URI.new!(uri)}

  defp instance_from_wire(%{"scope" => "spawned_by", "uri" => uri}),
    do: {:spawned_by, Ezagent.URI.new!(uri)}

  defp instance_from_wire(other), do: invalid_axis!(:instance, other)

  defp workspace_from_wire("any"), do: :any
  defp workspace_from_wire(s) when is_binary(s), do: Ezagent.URI.new!(s)
  defp workspace_from_wire(other), do: invalid_axis!(:workspace_uri, other)

  defp granted_by_from_wire("plugin_declared"), do: :plugin_declared
  defp granted_by_from_wire(s) when is_binary(s), do: Ezagent.URI.new!(s)
  defp granted_by_from_wire(other), do: invalid_axis!(:granted_by, other)

  defp invalid_axis!(axis, value) do
    raise ArgumentError,
          "Ezagent.Capability wire field #{axis} received an invalid axis value: #{inspect(value)}"
  end

  defp string_to_uri_or_nil(nil), do: nil
  defp string_to_uri_or_nil(s) when is_binary(s), do: Ezagent.URI.new!(s)

  defp encode_signature(nil), do: nil

  defp encode_signature(signature) when is_binary(signature),
    do: Base.url_encode64(signature, padding: false)

  defp decode_signature(nil), do: nil

  defp decode_signature(signature) when is_binary(signature) do
    case Base.url_decode64(signature, padding: false) do
      {:ok, raw_signature} ->
        raw_signature

      :error ->
        raise ArgumentError,
              "Ezagent.Capability.from_map/1: invalid base64url signature"
    end
  end

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
