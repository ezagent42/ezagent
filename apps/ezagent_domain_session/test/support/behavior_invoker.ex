defmodule EzagentDomainInstanceMessage.Test.BehaviorInvoker do
  @moduledoc """
  Test-only helper that calls a new-contract Behavior handler
  (`handle_<action>(args, ctx)`) directly, folds the returned
  effect list into a slice, and lifts the 3-tuple result back
  into the `{:ok, slice} | {:ok, slice, result} | {:error,
  reason}` shape Behavior contract tests assert against.

  This is the new-contract counterpart of the (now-deleted) Phase
  3 `BehaviorLegacyInvoke` shim. It has the same surface
  (`invoke/5`, `invoke_with_effects/5`) but is no longer a
  translation layer — it calls the per-action handler directly
  and packages the result.

  ## Why this is test-only

  The Kind.Runtime dispatch path (`Ezagent.Kind.Runtime.handle_dispatch/4`)
  is the production entry point: it does authz, workspace
  isolation, arg validation, slice fetch from registered Kind
  state, snapshot writes, and slice-change emission. That entire
  pipeline is over-specified for a unit test that just wants to
  assert "given slice X and args Y, the handler returns Z and
  mutates the slice to W". This helper invokes ONLY the handler
  with the right ctx shape and applies `:set` effects against
  the passed-in slice — no registry, no snapshot, no PubSub
  beyond the per-handler `:notify` effects.

  ## Usage

      alias EzagentDomainInstanceMessage.Test.BehaviorInvoker, as: Invoker

      assert {:ok, new_slice, %{stored: true}} =
               Invoker.invoke(Ezagent.ActionSet.Session, :send, slice, %{message: msg}, ctx)

  Or with effect introspection:

      assert {:ok, new_slice, result, effects} =
               Invoker.invoke_with_effects(Ezagent.ActionSet.Session, :send, slice, %{message: msg}, ctx)
  """

  @doc """
  Call a Behavior's `handle_<action>(args, ctx)` clause and fold
  the returned effects into a slice + result.

  Returns `{:ok, new_slice} | {:ok, new_slice, result} | {:error, reason}`
  to match the legacy invoke contract test assertions used.
  """
  @spec invoke(module(), atom(), map(), map(), map()) ::
          {:ok, map()}
          | {:ok, map(), term()}
          | {:error, term()}
  def invoke(behavior_module, action, slice, args, ctx) do
    case invoke_with_effects(behavior_module, action, slice, args, ctx) do
      {:ok, new_slice, nil, _effects} ->
        {:ok, new_slice}

      # Handlers that return an empty-map result (e.g. fire-and-forget
      # `:receive`) collapse to the 2-tuple shape so legacy assertion
      # `{:ok, ^slice}` keeps working.
      {:ok, new_slice, result, _effects} when result == %{} ->
        {:ok, new_slice}

      {:ok, new_slice, result, _effects} ->
        {:ok, new_slice, result}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Same as `invoke/5` but also returns the effect list (for tests
  that want to assert the shape of emitted :notify / :dispatch
  effects).

  Returns `{:ok, new_slice, result, effects}` on success.
  """
  @spec invoke_with_effects(module(), atom(), map(), map(), map()) ::
          {:ok, map(), term() | nil, [term()]}
          | {:error, term()}
  def invoke_with_effects(behavior_module, action, slice, args, ctx) do
    handler = String.to_atom("handle_" <> Atom.to_string(action))

    # Lifecycle two-container support (SPEC 2026-05-29 §2.3): a converted
    # Behavior reads persistent fields via `ctx.read` (over the flat
    # slice here) and TRANSIENT fields via `ctx.transients[k]`, writing
    # transients with `{:set_transient, k, v}` effects. A flat (legacy)
    # slice has no separate transient container, so we expose the SAME
    # flat slice as `ctx.transients` — the transient keys (e.g.
    # `:monitors`) live alongside the persistent ones in the test's flat
    # slice, and `apply_set_effects/2` folds BOTH `:set` and
    # `:set_transient` back onto that one flat map. This is additive:
    # behaviors that emit no `:set_transient` are unaffected.
    enriched_ctx =
      ctx
      |> Map.put_new(:kind_module, fixture_kind_module(behavior_module))
      # Unit callers model an authenticated boundary with `ctx.caller`; make
      # that boundary explicit before invoking the handler. This is test-only
      # normalization, never a production fallback.
      |> then(fn test_ctx ->
        case Map.get(test_ctx, :caller) do
          %URI{} = holder -> Map.put_new(test_ctx, :authenticated_principal, holder)
          _other -> test_ctx
        end
      end)
      |> normalize_identity_sibling_fixture()
      |> Map.put_new(:read, fn key, default -> Map.get(slice, key, default) end)
      |> Map.put_new(:transients, slice)

    # Ensure the behavior module is loaded before probing with
    # `function_exported?/3` — it reports `false` for a not-yet-loaded module
    # even when the clause exists. Most im behaviors are eagerly loaded by the
    # app boot, but session behaviors registered by a sibling app (e.g. Turn /
    # Surface, registered by the socialware app) are lazy when im is tested
    # standalone, so the probe would spuriously miss their handlers.
    _ = Code.ensure_loaded(behavior_module)

    if function_exported?(behavior_module, handler, 2) do
      case apply(behavior_module, handler, [args, enriched_ctx]) do
        {:ok, result, effects} when is_list(effects) ->
          new_slice = apply_set_effects(slice, effects)
          # Side-effect-shaped effects also need to actually run for
          # legacy assertion patterns to keep working — a test that
          # subscribes to PubSub before invoke and asserts_receive on
          # the broadcast expects the broadcast to actually happen.
          execute_notify_effects(effects)
          {:ok, new_slice, result, effects}

        {:ok, result} ->
          {:ok, slice, result, []}

        {:error, _reason} = err ->
          err

        other ->
          {:error, {:bad_handler_return, behavior_module, action, other}}
      end
    else
      {:error, {:missing_handler, behavior_module, handler}}
    end
  end

  # Membership-cap receive unit tests provide the recipient's pre-loaded
  # Identity sibling directly. The production runtime obtains that sibling from
  # a live, licensed Kind and all artifacts in it are target-signed. Preserve
  # those two boundary facts here: start the concrete holder Kind when needed
  # and sign any shorthand fixture cap with the target's current authority.
  # This remains test-only fixture normalization; production authorization has
  # no ctx.caller/self fallback and still fails closed through authorize/3.
  defp normalize_identity_sibling_fixture(
         %{self_uri: %URI{} = holder, kind_module: kind_module, siblings: siblings} = ctx
       )
       when is_atom(kind_module) and is_map(siblings) do
    case get_in(siblings, [:identity, :caps]) do
      nil ->
        ctx

      caps ->
        :ok = ensure_test_holder(holder, kind_module)

        signed =
          caps
          |> caps_to_list()
          |> Enum.map(&sign_fixture_cap(&1, holder))
          |> MapSet.new()

        put_in(ctx, [:siblings, :identity, :caps], signed)
    end
  end

  defp normalize_identity_sibling_fixture(ctx), do: ctx

  defp fixture_kind_module(Ezagent.ActionSet.User.Receive), do: Ezagent.Entity.User
  defp fixture_kind_module(Ezagent.ActionSet.Agent.Receive), do: Ezagent.Entity.Agent
  defp fixture_kind_module(_behavior_module), do: Ezagent.Entity.Session

  defp ensure_test_holder(holder, kind_module) do
    case Ezagent.KindRegistry.lookup(holder) do
      {:ok, _pid} ->
        :ok

      :error ->
        case Ezagent.Kind.spawn(kind_module, %{uri: holder}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "test holder spawn failed: #{inspect(reason)}"
        end
    end
  end

  defp sign_fixture_cap(
         %Ezagent.Capability{signature: signature, key_id: key_id} = cap,
         _holder
       )
       when is_binary(signature) and is_binary(key_id),
       do: cap

  defp sign_fixture_cap(%Ezagent.Capability{instance: %URI{} = target} = cap, holder) do
    {:ok, authority} =
      Ezagent.Cap.Authority.open(Ezagent.URI.instance(target), cap.kind)

    {:ok, artifact} =
      Ezagent.Cap.prepare_provenance(
        {:admin, Ezagent.Entity.User.admin_uri()},
        holder,
        cap
      )

    Ezagent.Cap.Authority.sign(authority, %{artifact | grant_id: Ecto.UUID.generate()})
  end

  defp caps_to_list(%MapSet{} = caps), do: MapSet.to_list(caps)
  defp caps_to_list(caps) when is_list(caps), do: caps
  defp caps_to_list(cap), do: List.wrap(cap)

  # Folds BOTH `:set` (persistent) and `:set_transient` (volatile)
  # effects onto the single flat test slice. For a flat slice the two
  # containers are co-located, so a `{:set_transient, :monitors, m}`
  # writes `:monitors` back where the test reads it via `new_slice.monitors`.
  defp apply_set_effects(slice, effects) do
    Enum.reduce(effects, slice, fn
      {:set, key, value}, acc -> Map.put(acc, key, value)
      {:set_transient, key, value}, acc -> Map.put(acc, key, value)
      _other_effect, acc -> acc
    end)
  end

  defp execute_notify_effects(effects) do
    Enum.each(effects, fn
      {:notify, topic, payload} ->
        Phoenix.PubSub.broadcast(EzagentCore.PubSub, topic, payload)

      _ ->
        :ok
    end)
  end
end
