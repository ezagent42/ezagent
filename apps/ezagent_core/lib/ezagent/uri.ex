defmodule Ezagent.URI do
  @moduledoc """
  URI helpers — thin convenience over stdlib `URI`.

  ## Canonical form + the silent-address-error class (URI hardening, 2026-05-30)

  > "URI机制是整个系统中最核心的机制，地址静默错误是不可接受的" —
  > silent address errors are unacceptable (Allen 2026-05-30).

  The single most expensive URI bug class in this codebase is the
  **silent address error**: the SAME logical URI has two structurally-
  different `%URI{}` representations. `URI.parse("entity://system/user/admin")`
  yields `authority: "system"` (deprecated RFC-2396); `URI.new!/1` /
  `Ezagent.URI.new!/1` yield `authority: nil` (RFC-3986). Every other
  field is identical, so the two `to_string/1` to the same bytes — but
  as structs they are NOT `==`. When one code path keys a `MapSet` /
  `Map` / ETS table / presence index with the `URI.parse` form and
  another looks up with the canonical form, the lookup SILENTLY misses
  (a `nil`/empty result, no crash).

  The defenses, in order of strength:

  1. **`new!/1`** — THE canonical constructor for Ezagent-scheme strings.
     Strict RFC-3986 (`authority: nil`), scheme-allowlist validated,
     3-segment-shape validated, and now `canonical!/1`-asserted as a
     post-condition.
  2. **`parse/1`** — non-raising inbound wrapper (`{:ok, uri} | {:error, _}`)
     for external boundaries that must surface a tagged error instead of
     crashing (Invariant #9). Yields the SAME canonical form as `new!/1`.
  3. **`canonical?/1`** — predicate: `authority == nil` (scheme-independent).
  4. **`canonical!/1`** — the structural GUARD: raises `ArgumentError`
     (loud) on a non-canonical `%URI{}` so a leaked authority-bearing
     struct crashes at the boundary instead of silently mismatching
     downstream. Call it on any inbound URI of uncertain provenance.
  5. **`with_action/3`** — build an `?action=` dispatch target through the
     canonical chokepoint, eliminating the stdlib-`URI.new!` query-target
     carve-out.

  The CI gate `EzagentCore.Invariants.UriCanonicalizationInvariantTest`
  forbids raw stdlib `URI.parse/1` / `URI.new!/1` / `URI.new/1` in
  product `lib/`. This module is the only sanctioned home for them.

  ## Shape (SPEC v3 §3.6 — Phase 9 PR-7 onwards)

  SPEC v3 §3.6 (Amendment 2 — Allen 2026-05-21) unifies the
  per-tenant URI shape across all per-tenant schemes. Every
  per-tenant URI carries its workspace as the first authority
  segment, so workspace identity is structural / O(1) extractable:

      <scheme>://<workspace>/<type>/<name>[?action=<behavior>.<action>]

  Applies to:

  - `entity://<workspace>/<type>/<name>` (PR-2)
  - `session://<workspace>/<template>/<name>` (PR-7 — type axis is
    the template name the session was instantiated from)
  - `template://<workspace>/<type>/<name>` (PR-7 — `<type>` is the
    template type axis: `agent`, `session`)
  - `resource://<workspace>/<type>/<name>` (PR-7 — `<type>` is the
    resource kind: `uploads`, etc.)

  Cross-cutting / structural schemes keep their pre-PR-7 shape:

      workspace://<name>             # the tenant root (SPEC v2 §5.1)
      system://<type>/<name>         # cross-workspace (SPEC v2 §5.10)

  - `<scheme>` is one of the registered schemes (see
    `Ezagent.URI.SchemeRegistry` — runtime ETS allowlist, PR #145).
  - `<workspace>` is the workspace name segment, matching the bare
    `<name>` of a `workspace://<name>` URI.
  - `<type>` is the value on the scheme's type axis (`user`/`agent`
    for `entity://`, template name for `session://`, etc.).
  - `<name>` is the instance identity. Sub-resource positions are
    reserved.
  - `?action=<behavior>.<action>` selects the Behavior + action to invoke
    (SPEC v2 §5.2, PR #148). The path is identity; the query carries the
    action verb.

  ### Examples

      entity://system/user/admin                             # PR-2 entity
      entity://team-alpha/agent/cc_demo?action=session.receive      # entity + action
      entity://team-alpha/agent/curl_my-deepseek              # cross-workspace entity
      session://demo-workspace/demo-class/main?action=session.send         # PR-7 session
      template://system/agent/cc-orchestrator                # PR-7 agent template
      template://team-alpha/session/code-review@abc123        # PR-7 session template
      resource://team-alpha/uploads/file-abc                  # PR-7 resource
      workspace://team-alpha                                     # unchanged (tenant root)
      workspace://team-alpha/main?action=routing.add_rule        # unchanged
      system://routing/default?action=add_rule                # unchanged (cross-workspace)

  ## SPEC v3 deltas

  - `entity://` (PR-2) + `session://` / `template://` / `resource://`
    (PR-7) require a workspace host and `/<type>/<name>` path. The
    previous 2-segment form is rejected at parse time with
    `ArgumentError: <scheme> URI must include type and name segments`.
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
    free-form prefix: `entity://<workspace>/agent/cc_demo-builder`
    (SPEC §5.14 + Phase 9 §3.1).

  ## Parser layering

  - `instance/1` is **positional**: it knows where the instance ends
    based on the scheme's authority shape (3-segment for per-tenant schemes,
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
  `/<type>/<name>` and the host is the workspace:

  - 2-segment per-tenant URIs raise with
    `ArgumentError: <scheme> URI must include type and name segments`.
  - 4+ segments (`session://demo-workspace/demo-class/main/extra`) raise with
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
          # Post-condition / defense-in-depth (URI hardening — "address
          # silent errors unacceptable", Allen 2026-05-30): `URI.new/1`
          # always yields the RFC-3986 `authority: nil` form, so this
          # cannot fire today. It is an assertion that pins the canonical
          # invariant against any future refactor of this function that
          # might re-introduce an authority-bearing struct (e.g. a switch
          # back to `URI.parse/1`). The cost is one struct field read.
          canonical!(u)
        else
          raise ArgumentError,
                "URI scheme #{inspect(scheme)} not registered. " <>
                  "Known: #{inspect(Ezagent.URI.SchemeRegistry.list_all())}"
        end

      {:error, part} ->
        raise ArgumentError, "URI parse failed at #{inspect(part)}: #{inspect(s)}"
    end
  end

  @doc """
  Non-raising inbound wrapper — `string |> URI.new/1 |> validate`,
  returning `{:ok, canonical_uri} | {:error, reason}`.

  This is the boundary constructor for surfaces that must NOT crash on
  malformed external input (Invariant #9 — "no silent drops at
  user-facing surfaces": surface a `{:error, _}`, don't let the process
  die). It yields the SAME canonical `%URI{}` `new!/1` produces — same
  scheme allowlist, same 3-segment validation, same `authority: nil`
  form — but converts the `ArgumentError` raises into tagged errors.

  Use `new!/1` for trusted/internal strings (let-it-crash); use
  `parse/1` at external boundaries (CLI args, HTTP params, plugin
  payloads) where a bad string is a user error, not a bug.

  ## Error reasons

  - `:missing_scheme` — no scheme component.
  - `{:unregistered_scheme, scheme}` — scheme not in the SchemeRegistry
    allowlist (e.g. a deleted `user://` / `agent://` or an external
    `http://`).
  - `{:malformed, part}` — `URI.new/1` itself rejected the string.
  - `{:invalid_shape, message}` — registered scheme but wrong authority
    shape (e.g. a 2-segment `entity://`).

  ## Examples

      iex> {:ok, u} = Ezagent.URI.parse("entity://system/user/admin")
      iex> u == Ezagent.URI.new!("entity://system/user/admin")
      true

      iex> Ezagent.URI.parse("not a uri at all ::::")
      {:error, {:malformed, _}}

      iex> Ezagent.URI.parse("http://example.com")
      {:error, {:unregistered_scheme, "http"}}
  """
  @spec parse(String.t()) ::
          {:ok, URI.t()}
          | {:error,
             :missing_scheme
             | {:unregistered_scheme, String.t()}
             | {:malformed, term()}
             | {:invalid_shape, String.t()}}
  def parse(s) when is_binary(s) do
    case URI.new(s) do
      {:ok, %URI{scheme: nil}} ->
        {:error, :missing_scheme}

      {:ok, %URI{scheme: scheme} = u} ->
        if Ezagent.URI.SchemeRegistry.registered?(scheme) do
          try do
            validate_3seg_shape!(u, s)
            {:ok, canonical!(u)}
          rescue
            e in ArgumentError -> {:error, {:invalid_shape, Exception.message(e)}}
          end
        else
          {:error, {:unregistered_scheme, scheme}}
        end

      {:error, part} ->
        {:error, {:malformed, part}}
    end
  end

  @doc false
  @spec strict_external_new(String.t()) :: {:ok, URI.t()} | {:error, term()}
  def strict_external_new(s) when is_binary(s), do: URI.new(s)

  @doc """
  Predicate — is this `%URI{}` in canonical RFC-3986 form?

  The canonical-form rule (SPEC 2026-05-27-uri-canonicalization §3.2;
  URI hardening 2026-05-30) is **structural and scheme-independent**:

      a %URI{} is canonical ⇔ its `:authority` field is nil

  This is the ONLY field on which `URI.parse/1` (deprecated RFC-2396,
  sets `:authority` to the host) and `URI.new/1` (RFC-3986, leaves it
  nil) diverge for the same input string. Both keep `:host`, `:path`,
  etc. identical. The `:authority` asymmetry is exactly what makes two
  structurally-different `%URI{}` for the same logical address fail
  `==` / `MapSet` / `Map`-key / ETS-key comparison — a SILENT
  `nil`/empty downstream result. `canonical?/1` is `true` for the form
  every Ezagent comparison relies on.

  Holds for EVERY scheme — `entity://`, `system://`, `workspace://`,
  and external `http://` alike — because `URI.new/1` always omits
  `:authority`. This intentionally does NOT re-check the Ezagent scheme
  allowlist or 3-segment shape: those are `new!/1`'s job at construction
  time. `canonical?/1` answers the narrower, comparison-critical
  question "could this struct silently mismatch a `new!/1`-built peer?".

  ## Examples

      iex> Ezagent.URI.canonical?(Ezagent.URI.new!("entity://system/user/admin"))
      true

      iex> Ezagent.URI.canonical?(URI.parse("entity://system/user/admin"))
      false

      iex> Ezagent.URI.canonical?(URI.new!("http://example.com"))
      true
  """
  @spec canonical?(URI.t()) :: boolean()
  def canonical?(%URI{authority: nil}), do: true
  def canonical?(%URI{}), do: false

  @doc """
  Assert canonical form — return the URI unchanged if canonical, else
  RAISE `ArgumentError` (loud) with the divergent `:authority` field
  spelled out.

  This is the structural guard that makes the silent-address-error
  class IMPOSSIBLE to express quietly: a leaked non-canonical `%URI{}`
  (e.g. one built via the deprecated `URI.parse/1`) CRASHES at the
  boundary that calls `canonical!/1` instead of slipping downstream and
  silently missing a `MapSet`/`Map`/ETS lookup. "Address silent errors
  are unacceptable" — Allen 2026-05-30.

  `new!/1` calls this as a post-condition; `parse/1` converts the raise
  into `{:error, {:invalid_shape, _}}`. Comparison-critical call sites
  (presence index keys, capability owner checks, slot-worker URIs) can
  call `canonical!/1` on an inbound `%URI{}` of uncertain provenance to
  turn a would-be silent mismatch into an immediate, attributable crash.

  Accepts any input; non-`%URI{}` values raise with a clear message
  rather than failing a downstream pattern match cryptically.

  ## Examples

      iex> u = Ezagent.URI.new!("entity://system/user/admin")
      iex> Ezagent.URI.canonical!(u) == u
      true

      iex> Ezagent.URI.canonical!(URI.parse("entity://system/user/admin"))
      ** (ArgumentError) non-canonical %URI{} ...
  """
  @spec canonical!(URI.t()) :: URI.t()
  def canonical!(%URI{authority: nil} = uri), do: uri

  def canonical!(%URI{authority: authority} = uri) do
    raise ArgumentError,
          "non-canonical %URI{} (authority: #{inspect(authority)}) reached a " <>
            "canonical boundary. The canonical RFC-3986 form has authority: nil " <>
            "(produced by Ezagent.URI.new!/1 or stdlib URI.new/1). This struct " <>
            "was almost certainly built by the deprecated URI.parse/1, which " <>
            "sets :authority and silently mismatches every ==/MapSet/Map/ETS key " <>
            "comparison against a canonical peer. Re-parse via Ezagent.URI.new!/1. " <>
            "Got: #{URI.to_string(uri)}"
  end

  def canonical!(other) do
    raise ArgumentError,
          "canonical!/1 requires a %URI{}; got: #{inspect(other)}"
  end

  @doc """
  Construct an action-bearing dispatch target from a canonical instance
  URI, routing through the canonical chokepoint.

  The pervasive pattern `URI.new!("\#{URI.to_string(uri)}?action=b.a")`
  (the SPEC §3.4 "query-target idiom", ~89 sites) appends an `?action=`
  query to a canonical instance URI to build a dispatch target. It uses
  *stdlib* `URI.new!/1`, which yields the right `authority: nil` struct
  BUT bypasses the SchemeRegistry + shape validation — a typo'd scheme
  or a malformed base would pass silently. `with_action/3` closes that
  gap: it canonical-asserts the base, re-parses the assembled string
  through `new!/1` (full validation), and returns a canonical target.

  This is the helper flagged in SPEC §10 OQ-2 to eliminate the stdlib
  `URI.new!/1` carve-out entirely (URI hardening 2026-05-30).

  ## Examples

      iex> base = Ezagent.URI.new!("entity://team-alpha/agent/cc_demo")
      iex> Ezagent.URI.with_action(base, :session, :receive) |> URI.to_string()
      "entity://team-alpha/agent/cc_demo?action=session.receive"
  """
  @spec with_action(URI.t(), atom() | String.t(), atom() | String.t()) :: URI.t()
  def with_action(%URI{} = base, behavior, action) do
    instance = base |> canonical!() |> instance()
    new!("#{URI.to_string(instance)}?action=#{behavior}.#{action}")
  end

  @doc """
  Build an `entity://` URI from semantic parts.

  The public argument order is workspace-first so callers do not encode URI
  segment positions. The on-wire order is also workspace-first:
  `entity://<workspace>/<type>/<name>`.
  """
  @spec entity(String.t() | atom(), String.t() | atom(), String.t() | atom()) :: URI.t()
  def entity(workspace, type, name) do
    type = segment!(type)

    unless type in ["user", "agent", "worker"] do
      raise ArgumentError,
            "entity type must be one of user, agent, worker; got: #{inspect(type)}"
    end

    per_tenant("entity", workspace, type, name)
  end

  @doc """
  Whether `uri` is a WELL-FORMED bare identity-principal instance entity URI —
  a canonical `entity://<workspace>/<user|agent|worker>/<name>` with NO
  extraneous fields (authority/userinfo/port/query/fragment/subresource path).

  The check RECONSTRUCTS the canonical principal from the URI's own
  workspace/type/name (via the centralized decomposition `workspace_name/1` +
  `type/1` + `name/1`) through `entity/3` (which `new!`s the canonical form —
  every extraneous field nil) and requires EXACT struct equality. Any crafted
  extra field makes the URI `!=` its canonical rebuild, so it is rejected. The
  authoritative caller-identity gate for fail-closed authorization predicates
  (P3-3 / P4 chat membership) — keeping the positional URI introspection in
  `Ezagent.URI` rather than scattered across domain predicates.

  Returns `false` for any non-`%URI{}`, non-entity, or non-canonical input
  (and never raises — a name `entity/3` cannot canonicalize fails closed).
  """
  @spec bare_principal?(term()) :: boolean()
  def bare_principal?(%URI{scheme: "entity"} = uri) do
    with {:ok, workspace} <- workspace_name(uri),
         {:ok, type} when type in ["user", "agent", "worker"] <- type(uri),
         {:ok, name} when is_binary(name) and name != "" <- name(uri) do
      uri == entity(workspace, type, name)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def bare_principal?(_), do: false

  @doc "Build an `entity://<workspace>/user/...` URI."
  @spec user(String.t() | atom(), String.t() | atom()) :: URI.t()
  def user(workspace, name), do: entity(workspace, :user, name)

  @doc "Build an `entity://<workspace>/agent/...` URI."
  @spec agent(String.t() | atom(), String.t() | atom()) :: URI.t()
  def agent(workspace, name), do: entity(workspace, :agent, name)

  @doc "Build an `entity://<workspace>/worker/...` URI."
  @spec worker(String.t() | atom(), String.t() | atom()) :: URI.t()
  def worker(workspace, name), do: entity(workspace, :worker, name)

  @doc "Build a `session://` URI from workspace, template, and name."
  @spec session(String.t() | atom(), String.t() | atom(), String.t() | atom()) :: URI.t()
  def session(workspace, template, name), do: per_tenant("session", workspace, template, name)

  @doc "Build a `template://` URI from workspace, type, and name."
  @spec template(String.t() | atom(), String.t() | atom(), String.t() | atom()) :: URI.t()
  def template(workspace, type, name), do: per_tenant("template", workspace, type, name)

  @doc "Build a `resource://` URI from workspace, type, and name."
  @spec resource(String.t() | atom(), String.t() | atom(), String.t() | atom()) :: URI.t()
  def resource(workspace, type, name), do: per_tenant("resource", workspace, type, name)

  @doc "Build a `workspace://` URI."
  @spec workspace(String.t() | atom()) :: URI.t()
  def workspace(name), do: new!("workspace://#{segment!(name)}")

  @doc "Build a `system://` URI."
  @spec system(String.t() | atom(), String.t() | atom()) :: URI.t()
  def system(type, name), do: new!("system://#{segment!(type)}/#{segment!(name)}")

  @doc """
  Return the canonical stable string key for a URI.

  URI values are opaque to callers, but ETS/DB/map boundaries still need a
  stable scalar key. Keep that conversion here so PR-D can change URI layout
  through `Ezagent.URI` instead of scattered `URI.to_string/1` call sites.
  """
  @spec stable_key(URI.t()) :: String.t()
  def stable_key(%URI{} = uri), do: uri |> canonical!() |> URI.to_string()

  @doc """
  Build a single-segment `system://<principal>` URI.

  System principals are a closed catalog of dispatch callers
  (`system://bootstrap`, `system://session-internal`). They are not part of
  the per-tenant workspace-first reorder and intentionally keep the current
  single-segment shape.
  """
  @spec system_principal(String.t() | atom()) :: URI.t()
  def system_principal(principal), do: new!("system://#{segment!(principal)}")

  defp per_tenant(scheme, workspace, type, name) do
    new!("#{scheme}://#{segment!(workspace)}/#{segment!(type)}/#{segment!(name)}")
  end

  defp segment!(value) when is_atom(value), do: value |> Atom.to_string() |> segment!()

  defp segment!(value) when is_binary(value) do
    cond do
      value == "" ->
        raise ArgumentError, "URI segment must not be empty"

      String.contains?(value, "/") ->
        raise ArgumentError, "URI segment must not contain /: #{inspect(value)}"

      true ->
        value
    end
  end

  defp segment!(value) do
    raise ArgumentError, "URI segment must be a string or atom; got: #{inspect(value)}"
  end

  # SPEC v3 §3.6 (Phase 9 PR-7) — unified per-tenant schemes MUST
  # have a 3-segment authority `<workspace>/<type>/<name>`. workspace:// +
  # system:// + unknown schemes are left alone (cross-cutting /
  # structural roots).
  @unified_per_tenant_schemes ~w(entity session template resource)

  # The workspace host is REQUIRED for every per-tenant scheme. Without this,
  # a URI like `session:///default/main` (empty host, valid /<type>/<name> path)
  # would pass the path-shape check and later fall back to the `:any` workspace —
  # silently turning a malformed URI into cross-workspace scope (authz hole).
  # Must precede the path-shape clauses (which don't constrain host).
  defp validate_3seg_shape!(%URI{scheme: scheme, host: host}, raw)
       when scheme in @unified_per_tenant_schemes and (is_nil(host) or host == "") do
    raise ArgumentError,
          "#{scheme} URI must include a non-empty workspace host (expected " <>
            "#{scheme}://<workspace>/<type>/<name>): " <> inspect(raw)
  end

  defp validate_3seg_shape!(%URI{scheme: scheme, path: nil}, raw)
       when scheme in @unified_per_tenant_schemes,
       do:
         raise(
           ArgumentError,
           "#{scheme} URI must include type and name segments (expected #{scheme}://<workspace>/<type>/<name>): " <>
             inspect(raw)
         )

  defp validate_3seg_shape!(%URI{scheme: scheme, path: "/" <> rest}, raw)
       when scheme in @unified_per_tenant_schemes do
    case String.split(rest, "/") do
      [type, name] when type != "" and name != "" ->
        :ok

      [_one] ->
        raise ArgumentError,
              "#{scheme} URI must include type and name segments (expected #{scheme}://<workspace>/<type>/<name>): " <>
                inspect(raw)

      [_type, _name | _extra] ->
        raise ArgumentError,
              "#{scheme} URI sub-resource positions are reserved (expected #{scheme}://<workspace>/<type>/<name>): " <>
                inspect(raw)

      _ ->
        raise ArgumentError,
              "#{scheme} URI must include type and name segments (expected #{scheme}://<workspace>/<type>/<name>): " <>
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
  `/<type>/<name>` path segments. The URI's identity spans workspace,
  type, AND name.

  **2-segment-authority schemes** (`system://`) keep the
  `host + /<first-path-segment>` split — trailing path segments
  (reserved for future named sub-resources like `/auth/login`) are
  stripped.

  **1-seg-authority schemes** (`workspace://`) drop the entire path
  to recover the bare instance form.

  Examples:
  - `entity://system/user/admin` → unchanged
  - `entity://team-alpha/agent/cc_demo?action=session.receive`
    → `%URI{scheme: "entity", host: "team-alpha", path: "/agent/cc_demo"}`
  - `session://demo-workspace/demo-class/main?action=session.send`
    → `%URI{scheme: "session", host: "demo-workspace", path: "/demo-class/main"}`
  - `template://system/agent/cc-orchestrator`
    → unchanged (already in instance form)
  - `system://routing/default?action=add_rule`
    → `%URI{scheme: "system", host: "routing", path: "/default"}`
  - `workspace://team-alpha/main?action=routing.add_rule`
    → `%URI{scheme: "workspace", host: "team-alpha", path: nil}` (1-seg)
  - `workspace://team-alpha` → unchanged

  Used by dispatch to find the instance pid in KindRegistry.
  """
  @spec instance(URI.t()) :: URI.t()
  def instance(%URI{path: nil} = uri), do: %URI{uri | query: nil, fragment: nil}

  def instance(%URI{scheme: scheme, path: "/" <> rest} = uri)
      when scheme in @unified_per_tenant_schemes do
    # SPEC v3 §3.6 — 3-segment authority for unified per-tenant schemes:
    # <scheme>://<workspace>/<type>/<name>. Workspace, type, and name
    # are all part of the URI's identity, so instance/1 keeps both path
    # segments. new!/1 already rejected non-3-segment forms; if we
    # encounter one here it means the URI was hand-constructed bypassing
    # new!/1 — treat as a programming error and leave the path
    # unchanged (let the caller find out via downstream lookup failure
    # rather than silently masking it).
    case String.split(rest, "/", parts: 3) do
      [_type, _name] ->
        %URI{uri | query: nil, fragment: nil}

      [type, name, _subresource] ->
        %URI{uri | path: "/" <> type <> "/" <> name, query: nil, fragment: nil}

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

  Entity URIs carry their workspace as the URI host:
  `entity://<workspace>/<type>/<name>`. This helper pulls the
  workspace name out and returns a stdlib `%URI{}` for the
  corresponding `workspace://<workspace>` URI.

  Used by:
  - Dispatch (Phase 9 PR-4) to derive caller / target workspace.
  - LiveAuth (Phase 9 PR-5) to derive `current_workspace_uri` from
    `current_entity_uri`.
  - Capability matcher (Phase 9 PR-3) to enforce workspace dimension.

  Examples:
  - `entity://system/user/admin` → `workspace://system`
  - `entity://team-alpha/agent/cc_demo` → `workspace://team-alpha`

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
  def entity_workspace_uri(%URI{scheme: "entity", host: workspace_name, path: "/" <> rest} = uri)
      when is_binary(workspace_name) and workspace_name != "" do
    case String.split(rest, "/", parts: 3) do
      [type, entity_name] when type != "" and entity_name != "" ->
        workspace(workspace_name)

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

  @doc """
  Return the workspace scope for a URI using centralized URI shape rules.

  Per-tenant schemes return a `workspace://...` URI. `workspace://` returns
  itself. `system://` and unknown schemes are cross-workspace and return
  `:any`, matching capability semantics.
  """
  @spec workspace_of(URI.t()) :: URI.t() | :any
  def workspace_of(%URI{scheme: "entity"} = uri) do
    uri
    |> instance()
    |> entity_workspace_uri()
  end

  def workspace_of(%URI{scheme: scheme} = uri)
      when scheme in ["session", "template", "resource"] do
    uri
    |> instance()
    |> workspace_from_per_tenant_path()
  end

  def workspace_of(%URI{scheme: "workspace"} = uri), do: instance(uri)
  def workspace_of(%URI{scheme: "system"}), do: :any
  def workspace_of(%URI{}), do: :any

  @doc "Return the workspace name for a URI when it has one."
  @spec workspace_name(URI.t()) :: {:ok, String.t()} | :error
  def workspace_name(%URI{scheme: "workspace", host: name})
      when is_binary(name) and name != "" do
    {:ok, name}
  end

  def workspace_name(%URI{} = uri) do
    case workspace_of(uri) do
      %URI{scheme: "workspace", host: name} when is_binary(name) and name != "" -> {:ok, name}
      _ -> :error
    end
  end

  @doc "Return the workspace name for a URI, raising when no workspace applies."
  @spec workspace_name!(URI.t()) :: String.t()
  def workspace_name!(%URI{} = uri) do
    case workspace_name(uri) do
      {:ok, name} ->
        name

      :error ->
        raise ArgumentError, "URI has no workspace scope: #{URI.to_string(uri)}"
    end
  end

  @doc "Return true when a URI uses the given scheme."
  @spec scheme?(URI.t(), String.t() | atom()) :: boolean()
  def scheme?(%URI{scheme: scheme}, expected_scheme) do
    scheme == segment!(expected_scheme)
  end

  @doc "Return true when a URI has the given structural type segment."
  @spec type?(URI.t(), String.t() | atom()) :: boolean()
  def type?(%URI{} = uri, expected_type) do
    type(uri) == {:ok, segment!(expected_type)}
  end

  @doc "Return true when a URI has the given identity name segment."
  @spec name?(URI.t(), String.t() | atom()) :: boolean()
  def name?(%URI{} = uri, expected_name) do
    name(uri) == {:ok, segment!(expected_name)}
  end

  @doc "Return the structural type-axis segment for URI schemes that have one."
  @spec type(URI.t()) :: {:ok, String.t()} | :error
  def type(%URI{scheme: scheme} = uri) when scheme in @unified_per_tenant_schemes do
    case per_tenant_path_segments(uri) do
      {type, _name} -> {:ok, type}
      _ -> :error
    end
  end

  def type(%URI{scheme: "system", host: type}) when is_binary(type) and type != "" do
    {:ok, type}
  end

  def type(%URI{}), do: :error

  @doc "Return the structural type-axis segment, raising when none applies."
  @spec type!(URI.t()) :: String.t()
  def type!(%URI{} = uri) do
    case type(uri) do
      {:ok, type} ->
        type

      :error ->
        raise ArgumentError, "URI has no type segment: #{URI.to_string(uri)}"
    end
  end

  @doc "Return the identity name segment for supported Ezagent URI schemes."
  @spec name(URI.t()) :: {:ok, String.t()} | :error
  def name(%URI{scheme: scheme} = uri) when scheme in @unified_per_tenant_schemes do
    case per_tenant_path_segments(uri) do
      {_type, name} when name != "" -> {:ok, name}
      _ -> :error
    end
  end

  def name(%URI{scheme: "workspace", host: name}) when is_binary(name) and name != "" do
    {:ok, name}
  end

  def name(%URI{scheme: "system", path: "/" <> name}) when name != "" do
    {:ok, name}
  end

  def name(%URI{}), do: :error

  @doc "Return the identity name segment, raising when none applies."
  @spec name!(URI.t()) :: String.t()
  def name!(%URI{} = uri) do
    case name(uri) do
      {:ok, name} ->
        name

      :error ->
        raise ArgumentError, "URI has no name segment: #{URI.to_string(uri)}"
    end
  end

  @doc """
  Extract an identity name from a URI path string.

  This helper exists for migration call sites that still receive a path
  fragment instead of a full `%URI{}`. It centralizes the current
  `/<type>/<name>` positional rule.
  """
  @spec name_from_path(String.t()) :: {:ok, String.t()} | :error
  def name_from_path(path) when is_binary(path) do
    path
    |> String.trim_leading("/")
    |> String.split("/", parts: 2)
    |> case do
      [workspace, name] when workspace != "" and name != "" -> {:ok, name}
      [name] when name != "" -> {:ok, name}
      _ -> :error
    end
  end

  @doc """
  Workspace-first URIs carry workspace in the host, not the path. This helper
  remains only for stale migration call sites and intentionally returns
  `:error` for path-only input.
  """
  @spec workspace_name_from_path(String.t()) :: {:ok, String.t()} | :error
  def workspace_name_from_path(path) when is_binary(path), do: :error

  @doc "Split a URI path or path-like instance string into non-empty segments."
  @spec path_segments(String.t()) :: [String.t()]
  def path_segments(path) when is_binary(path) do
    String.split(path, "/", trim: true)
  end

  defp workspace_from_per_tenant_path(%URI{host: workspace_name, path: "/" <> rest})
       when is_binary(workspace_name) and workspace_name != "" do
    case String.split(rest, "/", parts: 3) do
      [type, name] when type != "" and name != "" -> workspace(workspace_name)
      _ -> :any
    end
  end

  defp workspace_from_per_tenant_path(%URI{}), do: :any

  defp per_tenant_path_segments(%URI{path: "/" <> rest}) do
    case String.split(rest, "/", parts: 3) do
      [type, name] when type != "" and name != "" -> {type, name}
      _ -> :error
    end
  end

  defp per_tenant_path_segments(%URI{}), do: :error

  defp stale_cookie_message(%URI{} = uri) do
    "entity_workspace_uri/1 requires a 3-segment URI " <>
      "(entity://<workspace>/<type>/<name>); got: " <>
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
  - `entity://system/agent/py_default?action=agent.py_reset` → `{:ok, {:agent, :py_reset}}`
  - `entity://team-alpha/agent/cc_demo-builder?action=session.receive` → `{:ok, {:session, :receive}}`
  - `session://demo-workspace/demo-class/main?action=session.send` → `{:ok, {:session, :send}}`
  - `entity://team-alpha/agent/cc_demo-builder` → `{:error, :missing_action}`
  - `entity://team-alpha/agent/cc_demo-builder?action=` → `{:error, :missing_action}`
  - `entity://team-alpha/agent/cc_demo-builder?action=justone` → `{:error, :malformed_action}`
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
  - `entity://system/user/admin` → `""`
  - `entity://team-alpha/agent/cc_demo-builder?action=session.receive` → `"behavior/chat/receive"`
  - `entity://team-alpha/agent/cc_demo-builder/auth/login` → `"auth/login"`
  - `session://demo-workspace/demo-class/main?action=session.send` → `"behavior/chat/send"`
  """
  @spec subresource(URI.t()) :: String.t()
  def subresource(%URI{path: nil}), do: ""

  def subresource(%URI{scheme: scheme, path: "/" <> rest})
      when scheme in @unified_per_tenant_schemes do
    # SPEC v3 §3.6 — unified 3-segment authority:
    # /<type>/<name>[/<sub-resource>...]. new!/1 rejects
    # 4+ segment URIs at the top, so in practice this returns "".
    # The split is retained so manually-constructed URIs that bypass
    # new!/1 don't crash here.
    case String.split(rest, "/", parts: 3) do
      [_type, _name] -> ""
      [_type, _name, sub] -> sub
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
