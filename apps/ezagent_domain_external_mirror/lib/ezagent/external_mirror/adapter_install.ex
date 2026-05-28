defmodule Ezagent.ExternalMirror.AdapterInstall do
  @moduledoc """
  `Ezagent.ExternalMirror.AdapterInstall` — per-adapter installation
  side-effects that MUST run the moment an adapter becomes available
  in `AdapterRegistry`.

  ## Why this module exists (codex r2 HIGH-1 + HIGH-3 unified fix)

  Two boot-ordering bugs in PR-EM-3 had the same root cause:
  external_mirror's `Application.start/2` did a one-shot pass over
  `AdapterRegistry.list/0` and `external_mirror_bindings` at boot
  time, but adapter PLUGINS register LATER (chat depends on
  external_mirror; plugins depend on chat). So at the moment the
  one-shot ran, the AdapterRegistry was empty:

  - HIGH-1: BootReconciler skipped every persisted binding because no
    adapter was registered → persisted bindings stayed un-reconciled.
  - HIGH-3: `register_per_adapter_cap_subjects/0` registered ZERO
    cap subjects → workspace admins couldn't grant per-adapter caps.

  The fix is event-driven, NOT poll-driven: `AdapterRegistry.register/1`
  calls `install/1` immediately after a successful (fresh) insert.
  This guarantees that the moment any adapter is observable in the
  registry, BOTH its cap subject AND its persisted-binding Workers
  exist.

  ## What `install/1` does

  For the given `adapter_module`:

  1. Registers the per-adapter cap subject via
     `CapabilityRegistry.register/3` — uses
     `String.to_atom("allow_" <> adapter_id)` as the action atom
     (same shape the original `register_per_adapter_cap_subjects/0`
     used, so existing per-adapter caps in
     `caps_data_ownership.exs` / docs remain valid).
  2. Walks `BindingRow.list_for_adapter/1` for this `adapter_id` and
     idempotently spawns a Worker for each row via
     `WorkerSpawn.spawn/4`. Per **P16**, the spawn is idempotent —
     already-alive Workers return `{:error, {:already_started, _pid}}`
     which we accept as success.

  ## Tolerance — survives bare-test environments

  Adapter-registry / plugin-contract tests register adapters without
  starting `CapabilityRegistry`, `EzagentCore.Repo`, or the
  RootSupervisor. `install/1` must NOT fail those tests; each step is
  wrapped in a `rescue` that logs at `:debug` (so production boot
  failures still surface in logs but bare-unit tests stay green).

  Production boot order DOES start CapabilityRegistry + Repo +
  RootSupervisor before any plugin boots (the umbrella's mix deps
  enforce this), so the production path executes every step
  successfully.

  ## Idempotency

  `install/1` is safe to call repeatedly with the same
  `adapter_module`. `CapabilityRegistry.register/3` is idempotent on
  `(kind, action, behavior)` repeats; Worker spawns return
  `{:already_started, _}` on re-spawn. AdapterRegistry only calls
  `install/1` on the FRESH insert path (`:ok` return) — the
  `{:ok, :already_present}` branch skips because the prior register
  already installed.
  """

  require Logger

  alias Ezagent.CapabilityRegistry
  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRegistry, BindingRow, WorkerSpawn}

  @doc """
  Install per-adapter cap subject + reconcile persisted bindings for
  `adapter_module`. Called from `AdapterRegistry.register/1` on
  successful fresh insert (via `maybe_install/1`).

  Returns `:ok` always — every step is best-effort with logging;
  failures do not propagate so an `AdapterRegistry.register/1` in a
  bare-unit test (no CapabilityRegistry, no Repo) stays green.
  """
  @spec install(module()) :: :ok
  def install(adapter_module) when is_atom(adapter_module) do
    adapter_id = adapter_module.adapter_id()

    :ok = register_cap_subject(adapter_module, adapter_id)
    :ok = reconcile_persisted_bindings(adapter_id)

    :ok
  end

  @doc """
  SPEC docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md
  §5: register the cross-registry install hook for `adapter_id` via
  `Ezagent.Plugin.publish_after_all_registered/2`. Called from
  `AdapterRegistry.register/1` on a fresh insert.

  The hook subscribes to BOTH `AdapterRegistry` and `BindingRegistry`
  for this `adapter_id`. The primitive fires `install/1` exactly once
  when both have entries (whichever side calls `notify_subscribers/2`
  SECOND triggers fire). The fire-handler resolves `adapter_module`
  via `AdapterRegistry.lookup/1` at fire time so this entry-point
  doesn't need to capture it (mirrors the binding-first counterpart
  which doesn't have the module either).

  Idempotent — duplicate calls register the same hook twice in the
  RegistrationHooks table; both hooks fire when the registry pair
  resolves, but `install/1`'s body is itself idempotent (cap
  registration + spawn are both idempotent).

  Replaces the r5 HIGH-A `maybe_install`/`maybe_install_by_adapter_id`
  symmetric pair with a single call through the core primitive.
  """
  @spec ensure_install_hook_registered(String.t(), module()) :: :ok
  def ensure_install_hook_registered(adapter_id, _adapter_module)
      when is_binary(adapter_id) do
    register_install_hook(adapter_id)
  end

  @doc """
  Counterpart to `ensure_install_hook_registered/2` — called from
  `BindingRegistry.register_module/2` on a fresh insert.

  Same hook shape; the BindingRegistry side doesn't have the adapter
  module either, so both sides delegate to the same private
  `register_install_hook/1` which resolves the module from
  AdapterRegistry at fire time.
  """
  @spec ensure_install_hook_registered_for_adapter_id(String.t()) :: :ok
  def ensure_install_hook_registered_for_adapter_id(adapter_id) when is_binary(adapter_id) do
    register_install_hook(adapter_id)
  end

  defp register_install_hook(adapter_id) do
    Ezagent.Plugin.publish_after_all_registered(
      [
        {AdapterRegistry, adapter_id},
        {BindingRegistry, adapter_id}
      ],
      fn ->
        # Resolve adapter module at fire time — both sides delegate
        # here, so we cannot rely on a captured module. By the time the
        # hook fires both registries have entries; `lookup/1` resolves.
        case AdapterRegistry.lookup(adapter_id) do
          {:ok, adapter_module} ->
            install(adapter_module)
            :ok

          :error ->
            # Should be unreachable — the hook only fires when
            # AdapterRegistry.lookup/1 returns {:ok, _} per the primitive's
            # all_registered? check. Log + no-op as a structural-error
            # canary rather than crash the RegistrationHooks GenServer.
            Logger.error(
              "ExternalMirror.AdapterInstall: hook fired for adapter_id=" <>
                "#{inspect(adapter_id)} but AdapterRegistry.lookup/1 returned " <>
                ":error — RegistrationHooks invariant broken."
            )

            :ok
        end
      end
    )

    :ok
  end

  # ----- Step 1: per-adapter cap subject (HIGH-3 fix) ---------------------

  defp register_cap_subject(adapter_module, adapter_id) do
    %{behavior_module: behavior_module} = adapter_module.cap_subject()

    # `String.to_atom/1` here is bounded: `adapter_id` comes from
    # `adapter_module.adapter_id()` which is compile-time-fixed
    # plugin code, NOT caller input. Bounded by the number of
    # adapter modules loaded — fixed at deploy time.
    action = String.to_atom("allow_" <> adapter_id)

    CapabilityRegistry.register(Ezagent.Entity.Session, action, behavior_module)
    :ok
  rescue
    err ->
      Logger.debug(
        "ExternalMirror.AdapterInstall: cap subject registration skipped for " <>
          "#{inspect(adapter_module)} (adapter_id=#{inspect(adapter_id)}): " <>
          inspect(err)
      )

      :ok
  end

  # ----- Step 2: reconcile persisted bindings (HIGH-1 fix) ----------------

  defp reconcile_persisted_bindings(adapter_id) do
    rows = safe_list_for_adapter(adapter_id)

    Enum.each(rows, fn %BindingRow{} = row ->
      session_uri = Ezagent.URI.parse!(row.session_uri)

      case WorkerSpawn.spawn(
             session_uri,
             row.adapter_id,
             row.target_id,
             decode_opts(row.opts_json)
           ) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        other ->
          Logger.debug(
            "ExternalMirror.AdapterInstall: worker spawn deferred for " <>
              "#{row.session_uri}/#{row.adapter_id}/#{row.target_id}: " <>
              inspect(other)
          )

          :ok
      end
    end)

    :ok
  rescue
    err ->
      Logger.debug(
        "ExternalMirror.AdapterInstall: reconcile skipped for " <>
          "adapter_id=#{inspect(adapter_id)}: " <> inspect(err)
      )

      :ok
  end

  defp safe_list_for_adapter(adapter_id) do
    BindingRow.list_for_adapter(adapter_id)
  rescue
    # Repo not started / sandbox not checked out — empty list.
    _ -> []
  end

  defp decode_opts(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_opts(_), do: %{}
end
