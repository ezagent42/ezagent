defmodule Ezagent.ExternalMirror.Binding do
  @moduledoc """
  `Ezagent.ExternalMirror.Binding` — behaviour every external-mirror
  binding module declares.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §2.3 / §6. The full set of callbacks (`init/1`, `publish/2`,
  `terminate/2`, `adapter_module/0`) ships in **PR-EM-2** when the
  Worker Kind dispatch path lands.

  PR-EM-1 defines the minimal behaviour shape required by the
  `:ezagent_plugin_check` Grill-5 compiler gate + `Ezagent.Plugin.boot/1`
  registration:

  - `adapter_module/0` — Grill-5 bidirectional declaration target;
    the compiler asserts `binding.adapter_module() == adapter`.

  A plugin that ships a Binding compiles successfully against PR-EM-1
  by implementing only `adapter_module/0`; the GenServer-callback set
  (`init/1`, `publish/2`, `terminate/2`) expands in PR-EM-2.

  ## Bidirectional declaration (Grill 5)

  Each side names the OTHER so a misconfiguration (typo, copy-paste
  error, two-adapters-one-binding accident) fails the build, not the
  runtime. The compiler runs four checks per `(adapter, binding)`
  pair from `Ezagent.Plugin.adapters/0`:

  1. `adapter` implements `@behaviour Ezagent.ExternalMirror.Adapter`.
  2. `binding` implements `@behaviour Ezagent.ExternalMirror.Binding`.
  3. `adapter.binding_module() == binding`.
  4. `binding.adapter_module() == adapter`.
  5. `adapter != binding` (a single module implementing both
     behaviours is rejected — would dissolve the boundary).

  Per SPEC §5.1 + §9 (PR-EM-1 acceptance).
  """

  @doc """
  The Adapter module paired with this Binding (Grill-5 bidirectional
  declaration; the compiler asserts
  `binding.adapter_module() == adapter` AND
  `adapter.binding_module() == binding`).
  """
  @callback adapter_module() :: module()

  # PR-EM-2 will add `init/1`, `publish/2`, `terminate/2` as
  # `@callback`s here. They are documented in SPEC §2.3 + §6.1.
end
