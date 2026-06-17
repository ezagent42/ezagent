defmodule EzagentPluginLiveview.Admin.ContentAdminClient do
  @moduledoc """
  Thin client for admin LiveViews to write tenant content through the
  `EzagentPluginContent.Behavior.ContentAdmin` Behavior — CapBAC-enforced (P15),
  audited (P19), agent/CLI-reachable — instead of direct `File.write`/store calls
  behind ad-hoc `can_write?` flags.

  Re-route Phase 2: every admin editor LV (fast/soul/slots/skill/KB/version pages)
  uses this one path so the cap check, dispatch ctx, and dormant-user warmup live
  in a single place. The dispatch is the security boundary; `writable?/2` is only
  the UI affordance (show/hide controls), mirroring the dispatch-time check.
  """

  alias EzagentPluginContent.Behavior.ContentAdmin

  @doc """
  Dispatch a ContentAdmin `action` against `workspace_uri` carrying the caller's
  caps. Returns the dispatch result (`{:ok, _}` | `{:error, reason}`).
  """
  @spec dispatch(URI.t(), URI.t() | String.t(), Enumerable.t(), atom(), map()) ::
          {:ok, term()} | {:error, term()}
  def dispatch(%URI{} = workspace_uri, admin_uri, caps, action, args)
      when is_atom(action) and is_map(args) do
    target = Ezagent.URI.with_action(workspace_uri, :content_admin, action)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{caller: admin_uri, caps: caps, reply: {:caller_inbox, self()}}
    })
  end

  @doc """
  UI affordance: does `caps` include a cap authorizing a ContentAdmin write on
  `workspace_uri`? Mirrors the dispatch-time CapBAC (concrete instance/workspace,
  like `cap_for_action/3` builds) so controls match real authority.
  """
  @spec writable?(Enumerable.t(), URI.t()) :: boolean()
  def writable?(caps, %URI{} = workspace_uri) do
    needed = %{
      kind: :workspace,
      behavior: ContentAdmin,
      action: :write_skill,
      instance: workspace_uri,
      workspace_uri: workspace_uri
    }

    Enum.any?(caps, &Ezagent.Capability.matches?(&1, needed))
  end

  def writable?(_caps, _), do: false

  @doc """
  Load the caller's caps, spawning the (possibly dormant) user Kind first so
  `Identity.list_caps_for/1` returns the persisted caps instead of `[]`.
  """
  @spec load_caps(URI.t() | String.t() | nil) :: Enumerable.t()
  def load_caps(admin_uri) do
    ensure_user_alive(admin_uri)
    Ezagent.Identity.list_caps_for(admin_uri)
  end

  @doc "Human-facing message for a dispatch error reason."
  @spec error_msg(term()) :: String.t()
  def error_msg(:unauthorized), do: "无权限"
  def error_msg(reason), do: inspect(reason)

  defp ensure_user_alive(%URI{} = user_uri) do
    case Ezagent.KindRegistry.lookup(user_uri) do
      :error ->
        case Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: user_uri}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, {:already_registered, _}} -> :ok
          _ -> :ok
        end

      {:ok, _pid} ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp ensure_user_alive(uri) when is_binary(uri) do
    ensure_user_alive(Ezagent.URI.new!(uri))
  rescue
    _ -> :ok
  end

  defp ensure_user_alive(_), do: :ok
end
