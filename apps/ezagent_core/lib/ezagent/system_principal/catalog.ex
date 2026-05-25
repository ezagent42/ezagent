defmodule Ezagent.SystemPrincipal.Catalog do
  @moduledoc """
  The closed allowlist of system principal URIs and their permitted caps.

  Any `system://` URI used as a dispatch principal MUST appear here.
  `:ezagent_plugin_check` enforces this at compile time (Issue 3);
  the runtime `SystemPrincipal.ensure/1` enforces it at boot;
  invariant test `no_admin_caps_fallback_test.exs` is the test-time gate.

  Adding a 15th principal requires:
  1. Add row here.
  2. Update SPEC `2026-05-25-caps-cleanup-v1.md` §4.1 catalog table.
  3. Ship in a separate PR (review surface = "are we adding ambient authority?").

  Per `feedback_let_it_crash_no_workarounds` — every entry is closed;
  there is no fallback path that mints an ad-hoc principal.

  ## Cap strings vs cap structs

  The catalog records cap STRINGS (the canonical wire format that
  arrives in PR-CC-2). PR-CC-1 reads these via `Catalog.caps_for!/1`
  and either:

  - persists them into the principal's `:identity` slice via
    `SystemPrincipal.ensure/1` (the caps_json column carries strings),
    OR
  - translates them to the legacy `Ezagent.Capability` struct shape
    via `SystemPrincipal.caps/1` for callers that still feed
    `ctx.caps` (the field that PR-CC-2b removes).
  """

  @catalog %{
    "system://bootstrap" => ["*"],
    "system://boot-reconciler" => ["session.external_mirror.*"],
    "system://adapter-install" => ["session.*.bind"],
    "system://chat-router" => ["session.chat.send", "session.chat.system_message"],
    "system://chat-reply" => ["session.chat.send", "session.chat.reaction"],
    "system://worker-publish" => ["session.external_mirror.publish"],
    "system://template-materialize" => ["workspace.template.*", "session.*"],
    "system://orchestrator-tools" => ["session.*"],
    "system://session-internal" => ["session.chat.*", "workspace.workspace.read"],
    "system://agent-internal" => ["user.identity.grant_cap"],
    "system://workspace-loader" => ["workspace.workspace.*"],
    "system://mix-task" => ["*"],
    "system://feishu-binding-policy" => ["user.identity.grant_cap"],
    "system://lv-anon-mount" => []
  }

  @doc "Is this URI a registered system principal?"
  @spec member?(URI.t() | String.t()) :: boolean()
  def member?(uri), do: Map.has_key?(@catalog, normalize(uri))

  @doc """
  Permitted cap STRINGS for this principal. Raises if not in catalog.

  Per `feedback_let_it_crash_no_workarounds` — bad URI is a programmer
  error, not a degradable runtime state.
  """
  @spec caps_for!(URI.t() | String.t()) :: [String.t()]
  def caps_for!(uri) do
    key = normalize(uri)

    case Map.fetch(@catalog, key) do
      {:ok, caps} ->
        caps

      :error ->
        raise ArgumentError,
              "#{key} is not in Ezagent.SystemPrincipal.Catalog " <>
                "(SPEC caps-cleanup-v1 §4.1). " <>
                "Add the row to Catalog + SPEC + open a separate PR."
    end
  end

  @doc "List every catalog URI (for invariant test §9.5)."
  @spec uris() :: [String.t()]
  def uris, do: Map.keys(@catalog)

  defp normalize(%URI{} = u), do: URI.to_string(u)
  defp normalize(s) when is_binary(s), do: s
end
