defmodule Ezagent.World.SessionForkAction do
  @moduledoc """
  World socket-side handler for "复制配置，建新会话" (copy this session's config →
  new owned session — website journey segment 5).

  The world entry point for `Ezagent.Session.ConfigFork.fork_config/3` (the
  CLI/UI 同源 backend). `WorldLive`'s `session.fork_config` dispatch delegates
  here (mirroring how `Ezagent.World.ConversationActions` delegates each
  conversation action) so the dispatcher module stays a thin host.

  Threads the viewing caller + its live caps so the backend's `:create_session`
  cap check (CapBAC step 5.5) is the real authorization gate — the caller
  becomes the new session's owner. On success, deep-links to the new session; on
  failure, surfaces the reason via `last_dispatch_status` (no silent drop,
  Invariant #9) — the standard conversation-action error surface the React shell
  reads from `data-last-dispatch`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2]

  @doc """
  Copy `session_uri`'s config into a new session owned by the viewing caller,
  then open the new session's `?session=` deep-link. Optional `args`:
  `"new_template_name"` / `"short_name"` (non-empty strings override the
  backend's generated defaults).
  """
  @spec fork_config(Phoenix.LiveView.Socket.t(), URI.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def fork_config(socket, %URI{} = session_uri, args) when is_map(args) do
    caller = socket.assigns.current_entity_uri
    caps = Ezagent.World.PresenterCaps.load(socket)

    # Thread only non-empty string overrides; the backend generates unique
    # defaults otherwise.
    opts =
      for {key, value} <- [
            new_template_name: Map.get(args, "new_template_name"),
            short_name: Map.get(args, "short_name")
          ],
          is_binary(value) and value != "" do
        {key, value}
      end

    case Ezagent.Session.ConfigFork.fork_config(
           session_uri,
           %{caller: caller, caps: caps},
           opts
         ) do
      {:ok, %{session_uri: %URI{} = new_session_uri}} ->
        deep_link =
          "/sessions?session=" <>
            (new_session_uri |> URI.to_string() |> URI.encode_www_form())

        {:noreply,
         socket
         |> assign(:last_dispatch_status, "ok")
         |> push_patch(to: deep_link)}

      {:error, reason} ->
        status = if is_atom(reason), do: Atom.to_string(reason), else: inspect(reason)
        {:noreply, assign(socket, :last_dispatch_status, "error:" <> status)}
    end
  end
end
