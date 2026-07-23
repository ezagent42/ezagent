defmodule Ezagent.World.FeishuBindingDispatch do
  @moduledoc """
  Thin dispatch adapter: the world Feishu bindings surface → the formal
  `EzagentPluginFeishu.Behavior.UserBinding` ActionSet dispatch.

  Builds the `workspace://<target>?action=user_binding.<action>` target via
  `Ezagent.URI.with_action/3`. The `user_binding` segment is a descriptive
  label only — `Ezagent.URI.behavior_action/1` splits it off and only the
  action atom (`:bind` / `:unbind` / `:list_feishu_bindings`) drives
  `BehaviorRegistry` resolution (`Ezagent.Kind.BehaviorSet.resolve_action/3`
  reads the action alone) — so this label is intentionally NOT read from
  `EzagentPluginFeishu.Behavior.UserBinding.state_slice/0`: `ezagent_plugin_world`
  must not carry a compile-time dependency on `ezagent_plugin_feishu` (plugin
  isolation, P1) and a literal here carries zero dispatch-resolution risk.
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
    target = Ezagent.URI.with_action(workspace_uri, :user_binding, action)

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

  defp normalize_error({:bad_args, _, _}), do: :invalid_args
  defp normalize_error({:bad_args, _}), do: :invalid_args
  defp normalize_error({:invalid_args, _}), do: :invalid_args
  defp normalize_error({:unknown_action, _}), do: :invalid_args
  defp normalize_error(:not_found), do: :invalid_args

  defp normalize_error({:policy_apply_failed, _}), do: :binding_policy_failed

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
