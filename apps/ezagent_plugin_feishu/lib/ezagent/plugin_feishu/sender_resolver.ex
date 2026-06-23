defmodule EzagentPluginFeishu.SenderResolver do
  @moduledoc """
  Phase 6 PR 15 — translate Feishu transport identity into Ezagent
  dispatch identity.

  ## Three flows
  1. **Bound** open_id → use bound `entity://user/team-alpha/X` as caller; fetch caps
     from that User Kind's Identity slice. CapBAC at step 5.5 will
     accept anything that user is authorized for (BindingPolicy
     ensures `Ezagent.Entity.User.default_caps/0` is present on bind,
     so the user can dispatch into sessions).
  2. **Unbound** open_id → return a pending state. WebhookPlug /
     WsClient log it for admin attention but DO NOT dispatch the
     message (matches Allen's "默认权限应该是绑定一个 esr 用户"
     — no bind, no chat ability).
  3. **Missing open_id** (event has no sender) → return error.

  ## Why separate from WebhookPlug

  Both the existing HTTP webhook and the upcoming WS long-connect
  client need the SAME identity resolution. Putting it here means
  one source of truth; transport modules just pass `open_id` in and
  receive `{:ok, caller_uri, caps}` or `{:pending, open_id}`.
  """

  require Logger

  alias EzagentPluginFeishu.UserBinding

  @type result ::
          {:ok, caller_uri :: URI.t(), caps :: MapSet.t(Ezagent.Capability.t())}
          | {:pending, open_id :: String.t()}
          | {:error, term()}

  @doc """
  Resolve a Feishu sender map (the `"sender"` field of an event) to
  Ezagent caller + caps.
  """
  @spec resolve(map()) :: result()
  def resolve(%{"sender_id" => %{"open_id" => open_id}}) when is_binary(open_id),
    do: resolve_open_id(open_id)

  def resolve(%{"sender_id" => %{"user_id" => uid}}) when is_binary(uid) do
    # `user_id` is a different ID type on Feishu — for now we don't
    # bind on it. Log + return pending so admin can investigate.
    Logger.info("FeishuSenderResolver: sender presented user_id=#{uid} not open_id; pending")
    {:pending, "user_id:" <> uid}
  end

  def resolve(other) do
    Logger.warning("FeishuSenderResolver: malformed sender: #{inspect(other)}")
    {:error, :bad_sender}
  end

  defp resolve_open_id(open_id) do
    case UserBinding.resolve(open_id) do
      {:ok, %URI{} = bound_uri} ->
        # PR 17 follow-up: ensure the User Kind is live before reading
        # its caps. After server restart, bound user URIs aren't
        # automatically re-spawned (they only get spawned at bind time
        # or via explicit SpawnRegistry call). Without this auto-spawn,
        # `list_caps_for` finds no Kind → returns empty MapSet →
        # dispatch denied as :unauthorized despite the binding +
        # cap-grant having persisted in the snapshot.
        case Ezagent.KindRegistry.lookup(bound_uri) do
          {:ok, _pid} ->
            :ok

          :error ->
            _ = Ezagent.SpawnRegistry.spawn(bound_uri)
            :ok
        end

        caps = Ezagent.Identity.list_caps_for(bound_uri)
        {:ok, bound_uri, caps}

      :error ->
        {:pending, open_id}
    end
  end
end
