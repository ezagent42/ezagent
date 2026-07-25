defmodule Ezagent.Cmd do
  @moduledoc """
  Cmd — the dispatch envelope for `Ezagent.Router.dispatch/1`.

  Per SPEC `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md`
  §2.1, every Router dispatch begins by an adapter (LV / CLI / Channel
  / external mirror) constructing a `%Ezagent.Cmd{}` and handing it to
  `Ezagent.Router.dispatch/1`.

  Unlike the legacy `%Ezagent.Invocation{}` shape, `Cmd` carries an
  explicit `action` atom (instead of encoding action in the URI's
  `?action=` query string). The Router resolves the target Kind from
  `target` and the Behavior+handler from `action`.

  ## Field semantics

  | Field | Required | Meaning |
  |---|---|---|
  | `target` | YES | The Kind instance URI (`%URI{}`). Canonicalised by Router step 1. |
  | `action` | YES | The action atom declared on a Behavior attached to `target`'s Kind. |
  | `args` | YES | Map of args validated against the Behavior's `interface/0[action].args`. |
  | `ctx` | YES | Caller context — see below. |

  ## `ctx` shape

      %{
        caller: URI.t() | :vm_internal,      # principal initiating the dispatch (:vm_internal = trusted in-VM code)
        authenticated_principal: URI.t(), # holder fixed at the auth boundary
        reply: Ezagent.Invocation.reply_target(),  # where to route the result
        trace_id: String.t() | nil,          # optional — propagates across cross-Kind dispatches
        command_uuid: String.t() | nil,      # optional — caller-supplied idempotency key
        deadline_ms: pos_integer() | nil,    # optional — overrides default 5_000ms call timeout
        caps: MapSet.t(Ezagent.Capability.t()) | nil  # optional — Push-side cap bundle
      }

  ## Why a distinct struct from `Ezagent.Invocation`

  Per SPEC §2.1, the new `Cmd` shape decouples the action from the
  URI query-string convention. The legacy `Invocation` struct
  encoded action via `target?action=behavior.action`, which conflated
  identity (the URI) with intent (the action). `Cmd` separates them,
  enabling cleaner saga step descriptions and replay envelopes.

  Phase 3 deletion (2026-05-28) removed the legacy behavior-adapter
  module along with the legacy `Behavior.invoke/4` contract. The
  remaining `Invocation` struct is still emitted by some adapters; a
  future pass will migrate those callers to `Cmd` directly.
  """

  @enforce_keys [:target, :action, :args, :ctx]
  defstruct [:target, :action, :args, :ctx, origin: nil]

  @type ctx :: %{
          required(:caller) => URI.t() | :vm_internal,
          required(:reply) => Ezagent.Invocation.reply_target(),
          optional(:authenticated_principal) => URI.t(),
          optional(:trace_id) => String.t() | nil,
          optional(:command_uuid) => String.t() | nil,
          optional(:deadline_ms) => pos_integer() | nil,
          optional(:caps) => MapSet.t(term()) | nil
        }

  @type t :: %__MODULE__{
          target: URI.t(),
          action: atom(),
          args: map(),
          ctx: ctx(),
          origin: Ezagent.DispatchOrigin.t()
        }

  @doc """
  Build a `%Cmd{}` from a target URI, action, args, and ctx map.

  Convenience constructor that pre-fills defaults for optional
  `ctx` keys. The `target` may be a `%URI{}` or a binary that
  parses as one.
  """
  @spec new(URI.t() | String.t(), atom(), map(), map()) :: t()
  def new(target, action, args, ctx)
      when is_atom(action) and is_map(args) and is_map(ctx) do
    target_uri =
      case target do
        %URI{} = u -> u
        s when is_binary(s) -> Ezagent.URI.new!(s)
      end

    # #154 — NO implicit `caller` default. Every dispatch MUST name its
    # principal explicitly: a `%URI{}` entity, or `:vm_internal` for trusted
    # in-VM code. A missing caller is a programming error (let-it-crash) rather
    # than a silent trust grant (the old `caller: :system` default) or a silent
    # deny. The other ctx keys keep their defaults.
    caller =
      case Map.fetch(ctx, :caller) do
        {:ok, c} ->
          c

        :error ->
          raise ArgumentError,
                "Ezagent.Cmd.new/4 requires an explicit ctx.caller — a %URI{} entity, " <>
                  "or :vm_internal for trusted in-VM code. The implicit default was " <>
                  "removed in #154 (VM-internal-trust). target=#{inspect(target_uri)} " <>
                  "action=#{inspect(action)}"
      end

    %__MODULE__{
      target: target_uri,
      action: action,
      args: args,
      origin: :trusted_internal,
      ctx:
        Map.merge(
          %{
            reply: :ignore,
            trace_id: nil,
            command_uuid: nil,
            deadline_ms: nil,
            caps: nil
          },
          Map.put(ctx, :caller, caller)
        )
    }
  end

  @doc "Build an external command and overwrite any caller supplied by the request."
  @spec authenticated_external(URI.t() | String.t(), atom(), map(), URI.t(), map()) :: t()
  def authenticated_external(target, action, args, %URI{} = presenter, ctx \\ %{}) do
    ctx =
      ctx
      |> Map.put(:caller, presenter)
      |> Map.put(:authenticated_principal, presenter)

    target
    |> new(action, args, ctx)
    |> Map.put(:origin, :authenticated_external)
  end

  @doc "Build a command minted by reviewed framework code."
  @spec trusted_internal(URI.t() | String.t(), atom(), map(), URI.t() | :vm_internal, map()) ::
          t()
  def trusted_internal(target, action, args, caller, ctx \\ %{}) do
    new(target, action, args, Map.put(ctx, :caller, caller))
  end
end
