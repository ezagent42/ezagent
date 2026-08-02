defmodule Ezagent.Capability.Normalize do
  @moduledoc false

  alias Ezagent.Capability

  @doc """
  Serialize a `%Capability{}` to a JSON-safe STRING-keyed map: atoms/modules →
  strings, URIs → strings, `:any`
  → `"any"`, `granted_at` → ISO8601. Inverse of `from_map/1`. Backs
  `Ezagent.Capability.to_map/1`.

  Missing grant-protocol fields are corruption and raise at the strict field
  reads below. Durable carriers validate through `GrantArtifact` before calling
  this serializer.
  """
  @spec to_map(Capability.t()) :: map()
  def to_map(%Capability{} = cap) do
    %{
      "kind" => atom_or_module_to_string(cap.kind),
      "behavior" => atom_or_module_to_string(cap.behavior),
      "action" => atom_or_module_to_string(cap.action),
      "instance" => instance_to_wire(cap.instance),
      "workspace_uri" => workspace_to_wire(cap.workspace_uri),
      "granted_by" => granted_by_to_wire(cap.granted_by),
      "granted_at" => DateTime.to_iso8601(cap.granted_at),
      "signature" => encode_signature(cap.signature),
      "key_id" => cap.key_id,
      "grantee_uri" => uri_or_nil_to_string(cap.grantee_uri),
      "grant_id" => cap.grant_id
    }
  end

  @doc """
  Deserialize a complete JSON-decoded STRING-keyed map back to `%Capability{}`.
  Missing protocol axes raise; no compatibility defaults are applied. A present
  atom or module name is resolved independently of module load state. A genuinely
  unknown name becomes its own concrete, authorization-inert atom rather than
  widening to the `:any` wildcard. Issued-artifact completeness is enforced by
  `Ezagent.Cap.GrantArtifact`. Inverse of `to_map/1`; backs
  `Ezagent.Capability.from_map/1`.
  """
  @spec from_map(map()) :: Capability.t()
  def from_map(%{} = m) do
    %Capability{
      kind: string_to_atom_or_module(Map.get(m, "kind")),
      behavior: string_to_atom_or_module(Map.get(m, "behavior")),
      action: string_to_atom_or_module(Map.fetch!(m, "action")),
      instance: instance_from_wire(Map.get(m, "instance")),
      workspace_uri: workspace_from_wire(Map.fetch!(m, "workspace_uri")),
      granted_by: granted_by_from_wire(Map.get(m, "granted_by")),
      granted_at: parse_datetime(Map.get(m, "granted_at")),
      signature: decode_signature(Map.get(m, "signature")),
      key_id: Map.get(m, "key_id"),
      grantee_uri: string_to_uri_or_nil(Map.get(m, "grantee_uri")),
      grant_id: Map.get(m, "grant_id")
    }
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

  # Resolve a serialized axis value back to its concrete atom or module without
  # coupling correctness to which applications happen to be loaded. All callers
  # decode bounded, internally minted grant vocabulary; carrier boundaries reject
  # arbitrary external maps before this function is reached.
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
