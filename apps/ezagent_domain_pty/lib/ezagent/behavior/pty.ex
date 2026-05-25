defmodule Ezagent.Behavior.Pty do
  @moduledoc """
  Pty Behavior — `:write` action for an Agent Kind backed by a local
  `Ezagent.Domain.Pty.Server`.

  ## PR #146 (SPEC v2 §5.7) — agent-direct dispatch

  The previous synthetic `pty-input://default` singleton is dissolved.
  PTY input now dispatches to the target agent's own URI:

      entity://agent/team-alpha/cc_<name>?action=pty.write   args: %{bytes: "..."}

  The Agent Kind hosts this Behavior; `ctx.self_uri` (injected by
  `Ezagent.Kind.Runtime`) is the agent URI used to locate the
  PtyServer via the `Ezagent.Domain.Pty.lookup/1` facade
  (`EzagentDomainPty.Registry` is the underlying :via name source).

  ## Domain.Pty PR-A / PR-B (2026-05-21 SPEC v1)

  PtyServer (now `Ezagent.Domain.Pty.Server`) moved out of the cc
  plugin into the Tier-2 `ezagent_domain_pty` app in PR-A. PR-B
  (this PR) moves this Behavior module into the same app — the
  module atom name `Ezagent.Behavior.Pty` is unchanged, so all
  existing DB cap grants (`caps_json` references the string
  `"Elixir.Ezagent.Behavior.Pty"`) continue to resolve.

  The Behavior MODULE lives in `ezagent_domain_pty`; the
  REGISTRATION (binding Agent Kind → :write → this module) happens
  in `EzagentDomainChat.Application.start/2` where the
  `Ezagent.Entity.Agent` Kind is defined. `ezagent_domain_chat`
  gains `:ezagent_domain_pty` as an in-umbrella dep so this
  module is loadable at registration time.

  ## Critical invariant (IMPLEMENTATION_ROADMAP §1.3 #1)

  Every operator-typed byte goes through `Ezagent.Invocation.dispatch`
  → CapBAC step 5.5 → audit telemetry → PtyServer write. The xterm.js
  hook never touches the PtyServer directly or pushes raw PubSub.

  ## Cap shape

  - `kind: :agent`
  - `behavior: Ezagent.Behavior.Pty`
  - `instance: entity://agent/<flavor>_<name>` (per-agent) or `:any`

  Admin's triple-`:any` passes. Grant per-agent for non-admin users.
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:write]

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:write, "write input bytes to the Agent's PTY subprocess stdin"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :pty

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{write_calls: 0, total_bytes: 0}

  @impl Ezagent.Behavior
  def invoke(:write, slice, %{bytes: bytes}, ctx) when is_binary(bytes) do
    case Map.get(ctx, :self_uri) do
      %URI{} = agent_uri ->
        case Ezagent.Domain.Pty.lookup(agent_uri) do
          {:ok, pid} ->
            case Ezagent.Domain.Pty.Server.write_input(pid, bytes) do
              :ok ->
                # `slice` may be `%{}` on first write — the host Agent
                # Kind doesn't list `Behavior.Pty` in `behaviors/0`
                # (PR #146: cc plugin can't be a chat-domain dep, so the
                # Behavior is added via BehaviorRegistry at boot, not
                # statically declared). Initialize lazily from a base
                # map so re-writes accumulate normally.
                base = init_slice(%{})

                new_slice = %{
                  base
                  | write_calls: Map.get(slice, :write_calls, base.write_calls) + 1,
                    total_bytes: Map.get(slice, :total_bytes, base.total_bytes) + byte_size(bytes)
                }

                {:ok, new_slice, %{bytes_written: byte_size(bytes)}}

              err ->
                err
            end

          :error ->
            {:error, :no_pty_server}
        end

      _ ->
        {:error, {:invalid_ctx, :self_uri_missing}}
    end
  end

  def invoke(:write, _slice, _args, _ctx),
    do: {:error, {:invalid_args, :bytes_required}}

  @impl Ezagent.Behavior
  def interface do
    %{
      write: %{
        description: "Write raw bytes to the agent's PTY input stream",
        args: %{bytes: :string},
        returns: %{bytes_written: :integer},
        modes: [:call, :cast]
      }
    }
  end

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): per-entity Behavior
  # — the entity (user / agent) owns its own state for this Behavior.
  @impl Ezagent.Behavior
  def data_owner(%URI{} = entity_uri), do: Ezagent.URI.instance(entity_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

end
