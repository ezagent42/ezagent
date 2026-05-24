defmodule Ezagent.ExternalMirror.Adapter do
  @moduledoc """
  `Ezagent.ExternalMirror.Adapter` — behaviour every external-mirror
  adapter module declares.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §2.2 / §5. The full set of callbacks (`adapter_id/0`,
  `display_name/0`, `description/0`, `cap_subject/0`,
  `target_ownership_check/2`, `event_to_payload/1`, `binding_module/0`)
  ships in **PR-EM-2** when the Worker Kind dispatch path lands.

  PR-EM-1 defines the minimal behaviour shape required by the
  `:ezagent_plugin_check` Grill-5 compiler gate + `Ezagent.Plugin.boot/1`
  registration:

  - `adapter_id/0` — the registry key.
  - `display_name/0`, `description/0` — operator-facing strings the
    facade returns from `list_adapters/0`.
  - `binding_module/0` — Grill-5 bidirectional declaration target;
    the compiler asserts `adapter.binding_module() == binding`.

  A plugin that ships an Adapter compiles successfully against
  PR-EM-1 by implementing these four; the Worker-side callbacks
  expand in PR-EM-2. Implementing the PR-EM-2 callbacks early is
  harmless — they simply aren't dispatched until PR-EM-2 wires the
  Worker.

  ## Why a stub now and not after PR-EM-2

  The `Ezagent.Plugin.boot/1` extension in PR-EM-1 calls
  `assert_behaviour!(adapter, Ezagent.ExternalMirror.Adapter, ...)`.
  Without the behaviour module existing, that assertion has nothing
  to check and every plugin declaration silently passes. Defining
  the behaviour up-front (even with only the four PR-EM-1-relevant
  callbacks) makes the plugin contract enforceable from day one;
  PR-EM-2 ADDS callbacks without breaking PR-EM-1 plugins.
  """

  @doc "Stable string key — the AdapterRegistry's lookup key."
  @callback adapter_id() :: String.t()

  @doc "Operator-facing name (shown in admin LV picker)."
  @callback display_name() :: String.t()

  @doc "Operator-facing description (1-2 sentences)."
  @callback description() :: String.t()

  @doc """
  The Binding module paired with this Adapter (Grill-5 bidirectional
  declaration; the compiler asserts
  `adapter.binding_module() == binding` AND
  `binding.adapter_module() == adapter`).
  """
  @callback binding_module() :: module()

  # PR-EM-2 will add `cap_subject/0`, `target_ownership_check/2`,
  # `event_to_payload/1` as `@callback`s here. They are documented in
  # SPEC §2.2 + §5.
end
