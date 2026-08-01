defmodule Ezagent.Capability.Match do
  @moduledoc false

  alias Ezagent.Capability
  alias Ezagent.Capability.Scope

  @doc """
  The pure 5-axis capability match. A cap authorizes `needed` iff its
  `kind`, `behavior`, `action`, `instance`, and `workspace_uri` all match.
  The wildcard semantics are ASYMMETRIC: a HELD cap's `:any` wildcards
  `kind`/`behavior`/`action`/`instance` (a needed-side `:any` does NOT — it
  matches only an `:any` held value), so a concrete held cap never authorizes
  a wildcard request. `workspace_uri` is the exception — `:any` on EITHER side
  matches (`workspace_match?/2`). `instance` additionally honors the held
  cap's `{:within_session | :within_workspace | :spawned_by, _}` scope tuples
  for scope-bounded delegation. Every axis is mandatory. No process calls — it
  is the pure decision dispatch step 5.5 reuses. Backs
  `Ezagent.Capability.matches?/2`.
  """
  @spec matches?(Capability.t(), %{
          required(:kind) => atom(),
          required(:behavior) => module(),
          required(:action) => atom(),
          required(:instance) => URI.t(),
          required(:workspace_uri) => URI.t() | :any
        }) :: boolean()
  def matches?(%Capability{} = cap, %{
        kind: k,
        behavior: b,
        action: a,
        instance: i,
        workspace_uri: w
      }) do
    field_match?(cap.kind, k) and
      field_match?(cap.behavior, b) and
      field_match?(action_of(cap), a) and
      instance_match?(cap.instance, i) and
      workspace_match?(cap.workspace_uri, w)
  end

  @doc """
  Read a cap's mandatory `:action` axis. Missing protocol state raises.
  Backs `Ezagent.Capability.action_of/1`.
  """
  @spec action_of(Capability.t() | map()) :: atom()
  def action_of(cap), do: Map.fetch!(cap, :action)

  @doc """
  The logical-identity 5-tuple of a cap — `{kind, behavior, action, instance,
  workspace_uri}`. Top-level URI axes are normalized via
  `Ezagent.URI.stable_key/1`; URIs NESTED inside `instance` scope tuples
  (`{:within_session | :within_workspace | :spawned_by, URI.t()}`) are keyed by
  a TOTAL structural tuple of their logical components (see `uri_key/1`) so two
  logically-equal scoped URIs (a canonical `Ezagent.URI.new!/1` struct and its
  authority-bearing `URI.parse/1` twin — differing only in the deprecated
  `:authority` field) collapse to ONE key, fixing the silent
  MapSet/digest/revoke miss the old raw-struct passthrough caused. A structural
  key (not a serialization) keeps `identity_key/1` TOTAL over the exported
  `scope_tuple()` contract — every serializer (`Ezagent.URI.new!/1`,
  `stable_key/1`, `URI.to_string/1`) raises on some contract-valid `%URI{}`
  (codex review 2026-08-01). Deliberately EXCLUDES `granted_by`/`granted_at`
  provenance so revoke can match a held cap despite a different grant timestamp
  (codex review HIGH-1, 2026-05-26 — full-struct equality silently failed
  revoke). Backs `Ezagent.Capability.identity_key/1`.
  """
  @spec identity_key(Capability.t()) ::
          {atom() | :any, module() | :any, atom() | :any, String.t() | :any | {atom(), tuple()},
           String.t() | :any}
  def identity_key(
        %Capability{
          kind: k,
          behavior: b,
          instance: i,
          workspace_uri: w
        } = cap
      ),
      do: {k, b, action_of(cap), normalize_uri_for_key(i), normalize_uri_for_key(w)}

  @doc """
  Build the runtime `needed`-cap map for a `(kind_module, action,
  target_uri)` triple: `behavior` via `BehaviorRegistry.lookup/2` (`:unknown`
  on miss), `instance` as the target's bare instance URI, `workspace_uri` via
  `Scope.workspace_of/1`. Dispatch step 5.5 uses this default builder when a
  Behavior has not declared `required_caps/0`. Backs
  `Ezagent.Capability.cap_for_action/3`.
  """
  @spec cap_for_action(module(), atom(), URI.t()) :: %{
          kind: atom(),
          behavior: module(),
          action: atom(),
          instance: URI.t(),
          workspace_uri: URI.t() | :any
        }
  def cap_for_action(kind_module, action, %URI{} = target_uri)
      when is_atom(kind_module) and is_atom(action) do
    behavior =
      case Ezagent.BehaviorRegistry.lookup(kind_module, action) do
        {:ok, behavior_module} -> behavior_module
        :error -> :unknown
      end

    %{
      kind: kind_module.type_name(),
      behavior: behavior,
      action: action,
      instance: Ezagent.URI.instance(target_uri),
      workspace_uri: Scope.workspace_of(target_uri)
    }
  end

  defp field_match?(:any, _), do: true
  defp field_match?(same, same), do: true
  defp field_match?(_, _), do: false

  defp instance_match?(:any, _), do: true

  defp instance_match?({:within_session, %URI{} = session_uri}, %URI{} = needed_instance) do
    needed_str = URI.to_string(needed_instance)
    session_str = URI.to_string(session_uri)

    needed_str == session_str or String.starts_with?(needed_str, session_str <> "/")
  end

  defp instance_match?({:within_workspace, %URI{} = workspace_uri}, %URI{} = needed_instance) do
    case Scope.workspace_of(needed_instance) do
      %URI{} = needed_ws -> URI.to_string(needed_ws) == URI.to_string(workspace_uri)
      :any -> false
    end
  end

  defp instance_match?({:spawned_by, %URI{} = principal_uri}, %URI{} = needed_instance) do
    Ezagent.AgentLineage.spawned_in_lineage?(needed_instance, principal_uri)
  end

  defp instance_match?(%URI{} = held, %URI{} = needed),
    do: URI.to_string(held) == URI.to_string(needed)

  defp instance_match?(same, same), do: true
  defp instance_match?(_, _), do: false

  defp workspace_match?(:any, _), do: true
  defp workspace_match?(_, :any), do: true

  defp workspace_match?(%URI{} = held, %URI{} = needed),
    do: URI.to_string(held) == URI.to_string(needed)

  defp workspace_match?(_, _), do: false

  defp normalize_uri_for_key(%URI{} = u), do: Ezagent.URI.stable_key(u)

  # Scope-tuple instance axes (`{:within_session | :within_workspace |
  # :spawned_by, URI.t()}` — the three shapes of `Capability.scope_tuple()`)
  # carry a NESTED %URI{} the top-level `%URI{}` clause never sees. Key it by a
  # TOTAL structural tuple of the URI's logical components (`uri_key/1`) so two
  # logically-equal scoped URIs collapse to ONE key — a canonical
  # `Ezagent.URI.new!/1` struct and its authority-bearing `URI.parse/1` twin
  # differ ONLY in the deprecated `:authority` field, which `uri_key/1` ignores
  # — fixing the silent MapSet/digest/revoke miss the old raw-struct
  # passthrough caused.
  #
  # A STRUCTURAL key, NOT any serialization: the exported `scope_tuple()`
  # contract admits any `URI.t()` and `Capability.cap/5` stores it unvalidated,
  # so `identity_key/1` must be TOTAL over it. Every serializer raises on some
  # contract-valid `%URI{}`: `Ezagent.URI.new!/1` on unregistered schemes;
  # `stable_key/1`'s `canonical!/1` on an authority-bearing URI;
  # `URI.to_string/1` on a host-with-relative-path URI (codex review
  # 2026-08-01). Plain field access never raises. Match SEMANTICS are untouched:
  # this only rewrites the identity KEY.
  defp normalize_uri_for_key({scope, %URI{} = u})
       when scope in [:within_session, :within_workspace, :spawned_by] do
    {scope, uri_key(u)}
  end

  defp normalize_uri_for_key(other), do: other

  # TOTAL structural key for a nested scope %URI{}: the logical URI components,
  # deliberately EXCLUDING the deprecated `:authority` (redundant with
  # host/userinfo/port and the ONLY field that differs between a canonical
  # struct and its `URI.parse/1` twin). Field access never raises, so
  # `identity_key/1` stays total; all logical components are retained, so
  # distinct logical URIs stay distinct.
  defp uri_key(%URI{} = u),
    do: {u.scheme, u.userinfo, u.host, u.port, u.path, u.query, u.fragment}
end
