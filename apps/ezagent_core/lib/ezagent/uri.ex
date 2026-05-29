defmodule Ezagent.URI do
  @moduledoc """
  URI helpers — thin convenience over stdlib `URI`.

  ## Shape (SPEC v3 §3.6 — Phase 9 PR-7 onwards)

  SPEC v3 §3.6 (Amendment 2 — Allen 2026-05-21) unifies the
  per-tenant URI shape across all per-tenant schemes. Every
  per-tenant URI carries its workspace as the second authority
  segment, so workspace identity is structural / O(1) extractable:

      <scheme>://<type>/<workspace>/<name>[?action=<behavior>.<action>]

  Applies to:

  - `entity://<type>/<workspace>/<name>` (PR-2)
  - `session://<template>/<workspace>/<name>` (PR-7 — type axis is
    the template name the session was instantiated from)
  - `template://<type>/<workspace>/<name>` (PR-7 — `<type>` is the
    template type axis: `agent`, `session`)
  - `resource://<type>/<workspace>/<name>` (PR-7 — `<type>` is the
    resource kind: `uploads`, etc.)

  Cross-cutting / structural schemes keep their pre-PR-7 shape:

      workspace://<name>             # the tenant root (SPEC v2 §5.1)
      system://<type>/<name>         # cross-workspace (SPEC v2 §5.10)

  - `<scheme>` is one of the registered schemes (see
    `Ezagent.URI.SchemeRegistry` — runtime ETS allowlist, PR #145).
  - `<type>` is the value on the scheme's type axis (`user`/`agent`
    for `entity://`, template name for `session://`, etc.).
  - `<workspace>` is the workspace name segment, matching the bare
    `<name>` of a `workspace://<name>` URI.
  - `<name>` is the instance identity. Sub-resource positions are
    reserved.
  - `?action=<behavior>.<action>` selects the Behavior + action to invoke
    (SPEC v2 §5.2, PR #148). The path is identity; the query carries the
    action verb.

  ### Examples

      entity://user/system/admin                             # PR-2 entity
      entity://agent/team-alpha/cc_demo?action=chat.receive      # entity + action
      entity://agent/team-alpha/curl_my-deepseek              # cross-workspace entity
      session://demo-class/demo-workspace/main?action=chat.send         # PR-7 session
      template://agent/system/cc-orchestrator                # PR-7 agent template
      template://session/team-alpha/code-review@abc123        # PR-7 session template
      resource://uploads/team-alpha/file-abc                  # PR-7 resource
      workspace://team-alpha                                     # unchanged (tenant root)
      workspace://team-alpha/main?action=routing.add_rule        # unchanged
      system://routing/default?action=add_rule                # unchanged (cross-workspace)

  ## SPEC v3 deltas

  - `entity://` (PR-2) + `session://` / `template://` / `resource://`
    (PR-7) require 3-segment path (`/<workspace>/<name>`). The
    previous 2-segment form is rejected at parse time with
    `ArgumentError: <scheme> URI must include workspace segment`.
  - Helper `entity_workspace_uri/1` extracts a
    `workspace://<workspace>` URI from any entity URI.
  - `Ezagent.Capability.workspace_of/1` extracts workspace
    structurally from session/template/resource URIs (no longer
    a `WorkspaceRegistry` lookup for sessions).
  - `instance/1` for the unified schemes returns the full
    3-segment path stripped of query/fragment.

  ## SPEC v2 deltas (still in force)

  - `user://` + `agent://` schemes deleted — merged into `entity://` (PR #141).
  - `behavior_action/1` reads `?action=<behavior>.<action>` (PR #148).
  - Agent flavor (cc / curl / echo) lives in the name segment as a
    free-form prefix: `entity://agent/<workspace>/cc_demo-builder`
    (SPEC §5.14 + Phase 9 §3.1).

  ## Parser layering

  - `instance/1` is **positional**: it knows where the instance ends
    based on the scheme's authority shape (3-segment for entity,
    2-segment for system, 1-segment for legacy).
  - `behavior_action/1` is **named**: it pulls the `action` query param
    and splits it on `.` into `{behavior_atom, action_atom}`.

  ## Scheme allowlist — runtime ETS (PR #145)

  The set of accepted schemes is the live `Ezagent.URI.SchemeRegistry`
  ETS table, NOT a compile-time list. Plugins extend it only via
  `Ezagent.SpawnRegistry.register/2` (which co-registers).

  Boot-time seeded schemes (SPEC §5.6):
  `entity`, `workspace`, `session`, `template`, `resource`, `system`.

  Deleted (rejected by `new!/1`):
  - `user`, `agent` (PR #141 — merged into `entity://`)
  - `feishu` (PR #143 — plugin re-shaped, SPEC §5.8)
  - `routing-admin`, `pty-input` (PR #144 — synthetic singletons
    dissolved per SPEC §5.7)
  - `message` (PR #149 — `Ezagent.Message.uri` renamed `id`, SPEC §5.13;
    message identifiers are plain UUID strings, not URIs)
  """

  @doc """
  Construct a canonical Ezagent `%URI{}` from a binary (RFC-3986 form,
  `authority: nil`). The canonical constructor for Ezagent-scheme URIs.
  Raises on malformed input (let-it-crash — adapter is responsible for
  clean URIs).

  Named `new!/1` (not `parse!/1`) to end the confusion with the stdlib
  `URI.parse/1`, which builds a non-canonical authority-bearing struct.
  `Ezagent.URI.new!/1` is the sanctioned chokepoint that yields the
  canonical RFC-3986 `authority: nil` shape every Ezagent comparison
  relies on.

  Rejects any scheme not registered in `Ezagent.URI.SchemeRegistry` —
  the SPEC v2 §5.11 lockdown that prevents documentation-drift bugs
  like the deleted-but-still-accepted `feishu://` scheme.

  ## SPEC v3 — unified 3-segment authority

  For the per-tenant schemes (`entity://` PR-2; `session://` /
  `template://` / `resource://` PR-7), the path MUST be
  `/<workspace>/<name>`:

  - 2-segment paths (`session://demo-class/demo-workspace/main`) raise with
    `ArgumentError: <scheme> URI must include workspace segment`.
  - 4+ segments (`session://demo-class/demo-workspace/main/extra`) raise with
    `ArgumentError: <scheme> URI sub-resource positions are reserved`.

  Cross-cutting schemes (`workspace://`, `system://`) are unchanged
  — their authority shape is enforced by their own consumers.
  """
  @spec new!(String.t()) :: URI.t()
  def new!(s) when is_binary(s) do
    case URI.new(s) do
      {:ok, %URI{scheme: nil}} ->
        raise ArgumentError, "URI missing scheme: #{inspect(s)}"

      {:ok, %URI{scheme: scheme} = u} ->
        if Ezagent.URI.SchemeRegistry.registered?(scheme) do
          validate_3seg_shape!(u, s)
          u
        else
          raise ArgumentError,
                "URI scheme #{inspect(scheme)} not registered. " <>
                  "Known: #{inspect(Ezagent.URI.SchemeRegistry.list_all())}"
        end

      {:error, part} ->
        raise ArgumentError, "URI parse failed at #{inspect(part)}: #{inspect(s)}"
    end
  end

  # SPEC v3 §3.6 (Phase 9 PR-7) — unified per-tenant schemes MUST
  # have a 3-segment authority `/<workspace>/<name>`. workspace:// +
  # system:// + unknown schemes are left alone (cross-cutting /
  # structural roots).
  @unified_per_tenant_schemes ~w(entity session template resource)

  defp validate_3seg_shape!(%URI{scheme: scheme, path: nil}, raw)
       when scheme in @unified_per_tenant_schemes,
       do:
         raise(
           ArgumentError,
           "#{scheme} URI must include workspace segment (expected #{scheme}://<type>/<workspace>/<name>): " <>
             inspect(raw)
         )

  defp validate_3seg_shape!(%URI{scheme: scheme, path: "/" <> rest}, raw)
       when scheme in @unified_per_tenant_schemes do
    case String.split(rest, "/") do
      [_workspace, name] when name != "" ->
        :ok

      [_one] ->
        raise ArgumentError,
              "#{scheme} URI must include workspace segment (expected #{scheme}://<type>/<workspace>/<name>): " <>
                inspect(raw)

      [_workspace, _name | _extra] ->
        raise ArgumentError,
              "#{scheme} URI sub-resource positions are reserved (expected #{scheme}://<type>/<workspace>/<name>): " <>
                inspect(raw)

      _ ->
        raise ArgumentError,
              "#{scheme} URI must include workspace segment (expected #{scheme}://<type>/<workspace>/<name>): " <>
                inspect(raw)
    end
  end

  defp validate_3seg_shape!(_uri, _raw), do: :ok

  @doc """
  Return the instance form of a URI — drop query + fragment and (for
  legacy 1-seg schemes) any trailing sub-resource path segments.

  Under SPEC v2 §5.2 (PR #148), the action verb lives in the query
  string, NOT in the path. So instance/1 mostly just strips
  `query` + `fragment`. Path is the identity.

  **3-segment-authority schemes** (per-tenant — `entity://` PR-2,
  `session://` / `template://` / `resource://` PR-7): keep both
  `/<workspace>/<name>` segments. The URI's identity spans workspace
  AND name.

  **2-segment-authority schemes** (`system://`) keep the
  `host + /<first-path-segment>` split — trailing path segments
  (reserved for future named sub-resources like `/auth/login`) are
  stripped.

  **1-seg-authority schemes** (`workspace://`) drop the entire path
  to recover the bare instance form.

  Examples:
  - `entity://user/system/admin` → unchanged
  - `entity://agent/team-alpha/cc_demo?action=chat.receive`
    → `%URI{scheme: "entity", host: "agent", path: "/default/cc_demo"}`
  - `session://demo-class/demo-workspace/main?action=chat.send`
    → `%URI{scheme: "session", host: "default", path: "/default/main"}`
  - `template://agent/system/cc-orchestrator`
    → unchanged (already in instance form)
  - `system://routing/default?action=add_rule`
    → `%URI{scheme: "system", host: "routing", path: "/default"}`
  - `workspace://team-alpha/main?action=routing.add_rule`
    → `%URI{scheme: "workspace", host: "default", path: nil}` (1-seg)
  - `workspace://team-alpha` → unchanged

  Used by dispatch to find the instance pid in KindRegistry.
  """
  @spec instance(URI.t()) :: URI.t()
  def instance(%URI{path: nil} = uri), do: %URI{uri | query: nil, fragment: nil}

  def instance(%URI{scheme: scheme, path: "/" <> rest} = uri)
      when scheme in @unified_per_tenant_schemes do
    # SPEC v3 §3.6 (Phase 9 PR-7) — 3-segment authority for unified
    # per-tenant schemes: <scheme>://<type>/<workspace>/<name>. Both
    # workspace AND name are part of the URI's identity, so instance/1
    # keeps both. new!/1 already rejected non-3-segment forms; if we
    # encounter one here it means the URI was hand-constructed bypassing
    # new!/1 — treat as a programming error and leave the path
    # unchanged (let the caller find out via downstream lookup failure
    # rather than silently masking it).
    case String.split(rest, "/", parts: 3) do
      [_workspace, _name] ->
        %URI{uri | query: nil, fragment: nil}

      [workspace, name, _subresource] ->
        %URI{uri | path: "/" <> workspace <> "/" <> name, query: nil, fragment: nil}

      _ ->
        %URI{uri | query: nil, fragment: nil}
    end
  end

  def instance(%URI{scheme: "system", path: "/" <> rest} = uri) do
    # PR #146 SPEC v2 §5.1 + §5.10 — `system://<type>/<name>` is
    # 2-segment-authority (e.g. `system://routing/default`,
    # `system://bootstrap/default`).
    case String.split(rest, "/", parts: 2) do
      [_name_only] ->
        %URI{uri | query: nil, fragment: nil}

      [name, _subresource] ->
        %URI{uri | path: "/" <> name, query: nil, fragment: nil}
    end
  end

  def instance(%URI{path: _path} = uri) do
    # 1-segment-authority schemes (workspace://) — entire path is
    # sub-resource. Drop it to recover the bare instance form.
    %URI{uri | path: nil, query: nil, fragment: nil}
  end

  @doc """
  Extract the `workspace://<workspace>` URI from an `entity://` URI.

  SPEC v3 §3.3 (Phase 9 PR-2) — entity URIs carry their workspace as
  the first path segment under the type axis:
  `entity://<type>/<workspace>/<name>`. This helper pulls the
  workspace name out and returns a stdlib `%URI{}` for the
  corresponding `workspace://<workspace>` URI.

  Used by:
  - Dispatch (Phase 9 PR-4) to derive caller / target workspace.
  - LiveAuth (Phase 9 PR-5) to derive `current_workspace_uri` from
    `current_entity_uri`.
  - Capability matcher (Phase 9 PR-3) to enforce workspace dimension.

  Examples:
  - `entity://user/system/admin` → `workspace://system`
  - `entity://agent/team-alpha/cc_demo` → `workspace://team-alpha`

  Raises `ArgumentError` if the URI is not a 3-segment entity URI
  (e.g. a `session://` URI, a legacy 2-segment entity URI from a
  stale pre-Phase-9 cookie, or a non-URI input). Callers must
  dispatch to `Ezagent.WorkspaceRegistry.lookup/1` for non-entity
  URIs.

  V1 fix (Allen Feishu 2026-05-21) — was previously raising
  `MatchError` on 2-segment input via `[a, b] = String.split(...)`.
  Stale pre-Phase-9 cookies that slipped past LiveAuth's lax
  `parse_entity_uri/1` reached here and surfaced a cryptic 500 with
  no actionable error. Now raises with a clear message even though
  the read-side validation in `EzagentWeb.LiveAuth` is the
  structural prevention (defense in depth, per memory
  `feedback_let_it_crash_no_workarounds` — no back-compat shim,
  still let it crash, just crash informatively).
  """
  @spec entity_workspace_uri(URI.t()) :: URI.t()
  def entity_workspace_uri(%URI{scheme: "entity", path: "/" <> rest} = uri) do
    case String.split(rest, "/", parts: 2) do
      [workspace_name, entity_name] when workspace_name != "" and entity_name != "" ->
        URI.new!("workspace://" <> workspace_name) # uri-canonical-allow: §3.6 structural derivation from validated workspace name

      _ ->
        raise ArgumentError, stale_cookie_message(uri)
    end
  end

  def entity_workspace_uri(%URI{scheme: "entity"} = uri) do
    # path: nil or path: "" — same "not 3-segment" failure shape, same
    # actionable hint.
    raise ArgumentError, stale_cookie_message(uri)
  end

  def entity_workspace_uri(other) do
    raise ArgumentError,
          "entity_workspace_uri/1 requires %URI{scheme: \"entity\", ...}; got: " <>
            inspect(other)
  end

  defp stale_cookie_message(%URI{} = uri) do
    "entity_workspace_uri/1 requires a 3-segment URI " <>
      "(entity://<type>/<workspace>/<name>); got: " <>
      URI.to_string(uri) <>
      ". If this is from a stale session cookie, the user " <>
      "should sign in again — write side " <>
      "(EzagentWeb.SessionPrincipal.canonicalize) writes " <>
      "3-segment, read side validation " <>
      "(EzagentWeb.LiveAuth.parse_entity_uri) should reject " <>
      "2-segment before calling this function."
  end

  @doc """
  Parse the `?action=<behavior>.<action>` query parameter of a URI.
  Returns `{:ok, {behavior_atom, action_atom}}` or
  `{:error, :missing_action | :malformed_action}`.

  **PR #148 SPEC v2 §5.2** — action selection moved from the path
  suffix (`/behavior/<kind>/<action>`) to a query parameter. Path is
  identity; query carries the action verb.

  **Named parser** — sibling to a hypothetical `auth_action/1` that
  would read a different query key. Each named parser reads its own
  key and converts the value (e.g. dotted form for action+behavior).

  Examples:
  - `entity://agent/system/echo_default?action=echo.say` → `{:ok, {:echo, :say}}`
  - `entity://agent/team-alpha/cc_demo-builder?action=chat.receive` → `{:ok, {:chat, :receive}}`
  - `session://demo-class/demo-workspace/main?action=chat.send` → `{:ok, {:chat, :send}}`
  - `entity://agent/team-alpha/cc_demo-builder` → `{:error, :missing_action}`
  - `entity://agent/team-alpha/cc_demo-builder?action=` → `{:error, :missing_action}`
  - `entity://agent/team-alpha/cc_demo-builder?action=justone` → `{:error, :malformed_action}`
  """
  @spec behavior_action(URI.t()) ::
          {:ok, {atom(), atom()}} | {:error, :missing_action | :malformed_action}
  def behavior_action(%URI{query: query}) when is_binary(query) do
    decoded = URI.decode_query(query)

    case Map.get(decoded, "action") do
      nil ->
        {:error, :missing_action}

      "" ->
        {:error, :missing_action}

      action_str ->
        case String.split(action_str, ".", parts: 2) do
          [behavior, action] when behavior != "" and action != "" ->
            {:ok, {String.to_atom(behavior), String.to_atom(action)}}

          _ ->
            {:error, :malformed_action}
        end
    end
  end

  def behavior_action(_), do: {:error, :missing_action}

  @doc """
  Return the sub-resource portion of a URI as a string (no leading
  slash), or `""` if there is none.

  **Positional, uniform** — the mirror image of `instance/1`. Made
  public so future named parsers (e.g. `auth_action/1`) can reuse the
  same split rule without re-deriving it.

  Examples:
  - `entity://user/system/admin` → `""`
  - `entity://agent/team-alpha/cc_demo-builder?action=chat.receive` → `"behavior/chat/receive"`
  - `entity://agent/cc_demo-builder/auth/login` → `"auth/login"`
  - `session://demo-class/demo-workspace/main?action=chat.send` → `"behavior/chat/send"`
  """
  @spec subresource(URI.t()) :: String.t()
  def subresource(%URI{path: nil}), do: ""

  def subresource(%URI{scheme: scheme, path: "/" <> rest})
      when scheme in @unified_per_tenant_schemes do
    # SPEC v3 §3.6 (Phase 9 PR-7) — unified 3-segment authority:
    # /<workspace>/<name>[/<sub-resource>...]. new!/1 rejects
    # 4+ segment URIs at the top, so in practice this returns "".
    # The split is retained so manually-constructed URIs that bypass
    # new!/1 don't crash here.
    case String.split(rest, "/", parts: 3) do
      [_workspace, _name] -> ""
      [_workspace, _name, sub] -> sub
      _ -> ""
    end
  end

  def subresource(%URI{scheme: "system", path: "/" <> rest}) do
    # PR #146 — `system://` is 2-segment-authority (same as `entity://`).
    case String.split(rest, "/", parts: 2) do
      [_name_only] -> ""
      [_name, sub] -> sub
    end
  end

  def subresource(%URI{path: "/" <> sub}), do: sub
  def subresource(%URI{path: ""}), do: ""

  @doc """
  Known scheme allowlist — delegates to `Ezagent.URI.SchemeRegistry.list_all/0`
  (runtime ETS, PR #145). Returns the live set so diagnostics + tests
  reflect plugin-added schemes (e.g. those registered via
  `Ezagent.SpawnRegistry.register/2`).
  """
  @spec known_schemes() :: [String.t()]
  def known_schemes, do: Ezagent.URI.SchemeRegistry.list_all()
end
