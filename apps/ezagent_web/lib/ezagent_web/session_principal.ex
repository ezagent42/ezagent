defmodule EzagentWeb.SessionPrincipal do
  @moduledoc """
  The single authorized writer for the session `:current_entity_uri`
  AND `:current_workspace_uri` slots. Forces every auth path
  (password, magic link, registration, and whatever lands next —
  OAuth, WebAuthn, SAML) through one validating funnel.

  Allen 2026-05-20: the bare-handle login bug shipped because
  `session_controller.credentials_create` normalized its input for
  the auth check but then `put_session(:current_entity_uri, raw)`
  wrote the unnormalized string. The downstream
  `EzagentWeb.Plugs.RequireEntity` parsed it as a URI, found no
  scheme, and bounced to /login — login appeared to fail.

  This module prevents that class of bug architecturally rather than
  by remembering. `put/2`/`put/3` validates that the input normalizes
  to a parseable `entity://user/...` or `entity://agent/...` URI and
  RAISES `ArgumentError` if not. There is no `:ok | :error` tuple
  to forget to handle and no fallback that silently writes garbage.
  Per memory `feedback_let_it_crash_no_workarounds`.

  ## Phase 9 PR-5 (SPEC v3 §6.1)

  `put/2` and `put/3` now write BOTH `:current_entity_uri` AND
  `:current_workspace_uri`. The workspace slot is derived from the
  entity URI's workspace segment via
  `Ezagent.URI.entity_workspace_uri/1` — the invariant
  `current_workspace_uri == entity_workspace_uri(current_entity_uri)`
  is enforced AT the write site. There is no way to construct an
  inconsistent pair via this API.

  `clear/1` removes both slots; used by `/logout` AND
  `/workspaces/switch` (per SPEC v3 §6.4 amended: workspace switch is
  logout + re-auth, NOT in-place context swap, because entity URIs are
  workspace-bound — switching workspace IS switching entity).

  Convention: NO direct `put_session(conn, :current_entity_uri, _)`
  or `put_session(conn, :current_workspace_uri, _)` call is allowed
  anywhere else in the codebase. Two invariant tests assert this.
  """

  import Plug.Conn,
    only: [put_session: 3, delete_session: 2, configure_session: 2]

  @valid_hosts ["user", "agent"]

  @doc """
  Stores the canonical `entity://...` URI string in
  `:current_entity_uri` AND its derived `workspace://<name>` URI
  string in `:current_workspace_uri`. Accepts:

  - a full URI string (`"entity://user/system/admin"`) — passes through
  - a bare handle (`"admin"`, `"allen"`) — normalized to
    `"entity://user/<workspace>/<handle>"` (lowercased). For bare
    handles, `put/3` REQUIRES the `:workspace` opt — there is no
    silent default (SPEC #324 rev 3 / `feedback_let_it_crash_no_workarounds`).
    `put/2` is therefore only valid for full URI inputs; bare handles
    via `put/2` raise `ArgumentError`.

  Raises `ArgumentError` if the result is not a parseable
  `entity://user/...` or `entity://agent/...` URI, OR if a bare
  handle is passed without an explicit `:workspace` opt. The session
  is also rotated via `configure_session(renew: true)` so a stolen
  pre-auth session ID cannot be reused.
  """
  @spec put(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put(conn, raw), do: put(conn, raw, [])

  @doc """
  Same as `put/2` plus options. Currently:

  - `:workspace` — workspace name for bare-handle canonicalization
    (e.g. `"system"`, `"team-alpha"`). REQUIRED for bare handles per
    SPEC #324 rev 3 — `canonicalize/2` raises `ArgumentError` if a
    bare handle is passed without `:workspace`. Ignored when `raw` is
    already a full `entity://` URI (the URI carries its workspace
    segment structurally).
  """
  @spec put(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def put(conn, raw, opts) when is_binary(raw) and is_list(opts) do
    canonical = canonicalize(raw, opts)
    entity_uri = URI.parse(canonical)
    workspace_uri = Ezagent.URI.entity_workspace_uri(entity_uri)

    conn
    |> configure_session(renew: true)
    |> put_session(:current_entity_uri, canonical)
    |> put_session(:current_workspace_uri, URI.to_string(workspace_uri))
  end

  def put(_conn, other, _opts) do
    raise ArgumentError,
          "EzagentWeb.SessionPrincipal.put/3 expects a String principal, got: #{inspect(other)}"
  end

  @doc """
  Clears BOTH session slots and rotates the session ID. Used by
  `/logout` AND `/workspaces/switch` (per SPEC v3 §6.4 amendment —
  workspace switch is logout + re-auth, not in-place context swap).
  """
  @spec clear(Plug.Conn.t()) :: Plug.Conn.t()
  def clear(conn) do
    conn
    |> configure_session(renew: true)
    |> delete_session(:current_entity_uri)
    |> delete_session(:current_workspace_uri)
  end

  @doc """
  Returns the canonical entity URI string for `raw`. Same validation
  as `put/2` but pure — useful for tests and for code paths that
  need to construct the canonical form without writing to a session
  yet.

  Raises `ArgumentError` on invalid input.
  """
  @spec canonicalize(String.t()) :: String.t()
  def canonicalize(raw), do: canonicalize(raw, [])

  @doc """
  Same as `canonicalize/1` plus options. Currently:

  - `:workspace` — workspace name used for bare-handle canonicalization
    (e.g. `"system"`, `"team-alpha"`). REQUIRED — there is no silent
    default per SPEC #324. Callers (magic_link_controller / sign-in
    controller / etc.) must pass the workspace explicitly. Admin login
    passes `"system"`; tenant login passes the tenant's workspace
    name from the magic-link flow.
  """
  @spec canonicalize(String.t(), keyword()) :: String.t()
  def canonicalize(raw, opts) when is_binary(raw) and is_list(opts) do
    trimmed = String.trim(raw)

    workspace =
      cond do
        # Full URI: workspace is encoded structurally — no opts needed.
        String.starts_with?(trimmed, "entity://") ->
          nil

        # Bare handle: workspace must be supplied (SPEC #324 — no
        # silent "default" fallback).
        true ->
          Keyword.get(opts, :workspace) ||
            raise(
              ArgumentError,
              "EzagentWeb.SessionPrincipal.canonicalize/2 requires opts[:workspace] " <>
                "for bare-handle input (SPEC #324 — no silent \"default\" fallback). " <>
                "Admin login passes \"system\"; tenant login passes the tenant's " <>
                "workspace name; full entity:// URIs ignore the opt."
            )
      end

    candidate = normalize(raw, workspace)

    case URI.parse(candidate) do
      %URI{scheme: "entity", host: host} when host in @valid_hosts ->
        candidate

      _ ->
        raise ArgumentError,
              "EzagentWeb.SessionPrincipal: not a valid entity URI: #{inspect(raw)} " <>
                "(normalized to #{inspect(candidate)}). Expected entity://user/... or entity://agent/..."
    end
  end

  def canonicalize(other, _opts) do
    raise ArgumentError,
          "EzagentWeb.SessionPrincipal.canonicalize/1 expects a String, got: #{inspect(other)}"
  end

  # Phase 9 PR-5 (SPEC v3 §6.4 amended): bare-handle workspace is
  # required via opts[:workspace] (SPEC #324 rev 3 — no silent
  # default; the historical Phase 9 PR-2 default-`default` fallback
  # was removed in #335 + #386 audits per
  # `feedback_let_it_crash_no_workarounds`). `/login?workspace=<name>`
  # supplies the target workspace when the user arrives via the
  # workspace-switcher logout flow. Admin login passes `"system"`.
  defp normalize(input, workspace) do
    trimmed = String.trim(input)

    cond do
      String.starts_with?(trimmed, "entity://") ->
        trimmed

      String.match?(trimmed, ~r/^[a-zA-Z0-9_-]+$/) ->
        "entity://user/" <> workspace <> "/" <> String.downcase(trimmed)

      true ->
        trimmed
    end
  end
end
