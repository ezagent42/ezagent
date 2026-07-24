defmodule Ezagent.World.FeishuBindingDispatch do
  @moduledoc """
  Thin dispatch adapter: the world Feishu bindings surface → the formal
  `EzagentPluginFeishu.Behavior.UserBinding` ActionSet dispatch.

  Builds the `workspace://<target>?action=feishu_user_bindings.<action>` target
  via `Ezagent.URI.with_action/3`. The label `feishu_user_bindings` is the
  Behavior's `state_slice/0` value, used here as a literal (not read at
  compile time — `ezagent_plugin_world` has no compile-time dependency on
  `ezagent_plugin_feishu` per P1 plugin isolation). `behavior_action/1`
  splits on `.` and only the action atom drives `BehaviorRegistry` resolution,
  but keeping the label consistent with the Behavior's own `state_slice`
  makes log entries, telemetry, and handoff-to-handoff tracing unambiguous.
  This module wraps the target in a real `%Ezagent.Invocation{mode: :call,
  origin: :authenticated_external}` carrying the CALLER's own identity/caps, and
  normalizes every raw dispatch/handler reason into a small closed set of
  stable, redacted error codes. Callers of this module (`WorkspacePluginData`,
  `WorkspacePluginActions`) never see `inspect/1` output, a full open_id, a
  full user URI, or an internal tuple — only one of `t:error_code/0`.

  Every call runs synchronously in the calling process (no `Task`/spawn), so
  when the caller is already inside `Ezagent.Invocation.with_admin_operator/2`
  (world_live.ex wraps every `world:dispatch` handler in it), the
  canonical-admin convenience auto-mint in `Invocation.dispatch/1` still
  applies transparently — this module does not need to (and must not)
  re-wrap it or fabricate an admin caller/caps for a non-canonical caller.

  This module does NOT duplicate the Behavior's workspace / anti-hijack /
  policy / rollback rules — those live exclusively in
  `EzagentPluginFeishu.Behavior.UserBinding` and are proven by its own tests.
  """

  alias Ezagent.Invocation

  @type error_code ::
          :unauthorized
          | :cross_workspace_denied
          | :invalid_args
          | :binding_policy_failed
          | :binding_rollback_failed
          | :binding_unavailable
          | :binding_operation_failed

  @doc """
  List Feishu bindings scoped to `workspace_uri`, via the formal
  `:list_feishu_bindings` action. Returns JSON-safe maps (string keys and
  values) ready for the world state channel.
  """
  @spec list(URI.t(), URI.t(), Enumerable.t()) :: {:ok, [map()]} | {:error, error_code()}
  def list(%URI{scheme: "workspace"} = workspace_uri, %URI{} = caller_uri, caps) do
    with {:ok, %{bindings: bindings}} <-
           call(workspace_uri, :list_feishu_bindings, %{}, caller_uri, caps) do
      {:ok, Enum.map(bindings, &jsonable_binding/1)}
    end
  end

  @doc """
  List bindings for the initial page load — the sanctioned entry point that
  `WorkspacePluginData.component_state` calls before any user interaction.

  The initial `state_for` call runs OUTSIDE the `with_admin_operator` wrapper
  that `world_live.ex` applies to `world:dispatch` events, so the canonical
  admin would see `bindings_error: "unauthorized"` with no caps. This function
  reuses the same `Invocation.with_admin_operator/2` seam (Decision 6) for the
  initial read: canonical admin auto-mints the precise action cap; every other
  caller goes through their real caps with zero privilege escalation.
  """
  @spec list_for_initial_state(URI.t(), URI.t(), Enumerable.t()) ::
          {:ok, [map()]} | {:error, error_code()}
  # DEFERRED B2-auth: the `with_admin_operator` convenience and the
  # `canonical_admin?/1` predicate below are NOT a permanent authorization
  # scheme — they are the existing sanctioned seam (`world_live.ex` already
  # wraps every `world:dispatch` handler in it).  A later thin B2-auth
  # slice will replace this with real operator-cap acquisition.
  def list_for_initial_state(%URI{scheme: "workspace"} = workspace_uri, %URI{} = caller_uri, caps) do
    if canonical_admin?(caller_uri) do
      Invocation.with_admin_operator(caller_uri, fn ->
        list(workspace_uri, caller_uri, MapSet.new())
      end)
    else
      list(workspace_uri, caller_uri, caps)
    end
  end

  @doc """
  Bind `open_id` to `user_uri` within `workspace_uri`, via the formal `:bind`
  action. `user_uri` is a plain string (as typed into the bind form or read
  from world state) — the Behavior's `args: %{user_uri: :uri}` schema is
  enforced by `Ezagent.InterfaceValidator` BEFORE the handler runs and
  strictly requires an actual `%URI{}` struct, so it is parsed here; an
  unparseable string normalizes to `:invalid_args` same as any other bad
  input, never a raised exception.
  """
  @spec bind(URI.t(), URI.t(), Enumerable.t(), String.t(), String.t()) ::
          {:ok, %{open_id: String.t(), user_uri: String.t()}} | {:error, error_code()}
  def bind(
        %URI{scheme: "workspace"} = workspace_uri,
        %URI{} = caller_uri,
        caps,
        open_id,
        user_uri
      )
      when is_binary(open_id) and is_binary(user_uri) do
    case parse_uri(user_uri) do
      {:ok, parsed} ->
        call(workspace_uri, :bind, %{open_id: open_id, user_uri: parsed}, caller_uri, caps)

      :error ->
        {:error, :invalid_args}
    end
  end

  @doc "Unbind `open_id` within `workspace_uri`, via the formal `:unbind` action."
  @spec unbind(URI.t(), URI.t(), Enumerable.t(), String.t()) ::
          {:ok, String.t()} | {:error, error_code()}
  def unbind(%URI{scheme: "workspace"} = workspace_uri, %URI{} = caller_uri, caps, open_id)
      when is_binary(open_id) do
    with {:ok, %{unbound: unbound}} <-
           call(workspace_uri, :unbind, %{open_id: open_id}, caller_uri, caps) do
      {:ok, unbound}
    end
  end

  @doc "Stable, redacted string for `t:error_code/0` — safe for the JSON world-state channel."
  @spec code_string(error_code()) :: String.t()
  def code_string(code) when is_atom(code), do: Atom.to_string(code)

  # -- internals ------------------------------------------------------------

  defp call(%URI{} = workspace_uri, action, args, %URI{} = caller_uri, caps) do
    target = Ezagent.URI.with_action(workspace_uri, :feishu_user_bindings, action)

    %Invocation{
      target: target,
      mode: :call,
      args: args,
      origin: :authenticated_external,
      ctx: %{
        caller: caller_uri,
        authenticated_principal: caller_uri,
        caps: MapSet.new(caps),
        reply: {:caller_inbox, self()}
      }
    }
    |> Invocation.dispatch()
    |> normalize()
  end

  defp normalize({:ok, _} = ok), do: ok
  defp normalize(:ok), do: {:ok, %{}}
  defp normalize({:error, reason}), do: {:error, normalize_error(reason)}

  @spec normalize_error(term()) :: error_code()
  defp normalize_error(:unauthorized), do: :unauthorized
  defp normalize_error(:missing_cap), do: :unauthorized
  defp normalize_error(:authenticated_principal_required), do: :unauthorized

  defp normalize_error(:cross_workspace_denied), do: :cross_workspace_denied
  defp normalize_error({:cross_workspace_user, _}), do: :cross_workspace_denied
  defp normalize_error({:cross_workspace_rebind, _}), do: :cross_workspace_denied

  defp normalize_error({:not_entity_uri, _}), do: :invalid_args
  defp normalize_error({:not_user_entity, _}), do: :invalid_args
  defp normalize_error({:binding_policy_failed, _}), do: :binding_policy_failed
  defp normalize_error({:binding_rollback_failed, _}), do: :binding_rollback_failed
  defp normalize_error({:bad_args, _, _}), do: :invalid_args
  defp normalize_error({:bad_args, _}), do: :invalid_args
  defp normalize_error({:invalid_args, _}), do: :invalid_args
  defp normalize_error({:unknown_action, _}), do: :invalid_args
  defp normalize_error(:not_found), do: :invalid_args

  defp normalize_error(reason)
       when reason in [
              :not_ready,
              :activate_timeout,
              :no_such_actor,
              :buffer_full,
              :stale_incarnation
            ],
       do: :binding_unavailable

  defp normalize_error(_other), do: :binding_operation_failed

  defp canonical_admin?(%URI{} = caller) do
    Ezagent.URI.stable_key(caller) ==
      Ezagent.URI.stable_key(Ezagent.URI.user(:system, :admin))
  end

  defp parse_uri(str) do
    {:ok, Ezagent.URI.new!(str)}
  rescue
    _ -> :error
  end

  defp jsonable_binding(%{} = binding) do
    Map.new(binding, fn {k, v} -> {to_string(k), jsonable_value(v)} end)
  end

  defp jsonable_value(%DateTime{} = v), do: DateTime.to_iso8601(v)
  defp jsonable_value(%NaiveDateTime{} = v), do: NaiveDateTime.to_iso8601(v)
  defp jsonable_value(%URI{} = v), do: URI.to_string(v)
  defp jsonable_value(v), do: v
end
