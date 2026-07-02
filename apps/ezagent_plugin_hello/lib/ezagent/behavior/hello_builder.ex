defmodule Ezagent.ActionSet.HelloBuilder do
  @moduledoc """
  The hello builder agent Behavior — the session member that turns a user's
  request into a generated `@json-render` page.

  On `:receive` (the chat fan-out hook — the session's `chat.send` dispatches
  `chat.receive` to every member) of a USER message, it kicks off page
  generation: `EzagentPluginHello.Generator` calls the LLM with the page-gen
  prompt, extracts + validates the `@json-render` spec, and drives the session's
  `Behavior.Turn` to land it in `Behavior.Surface` (the chokepoint — see
  `EzagentPluginHello.TurnDriver`). The visitor then sees it via `ExternalFeed`.

  ## Phase 0 transport note (deviation from the curl-flavor plan, documented)

  Generation runs in a supervised Task spawned from this handler, calling the
  hello LLM client directly — NOT through `AgentBridge` + a registered
  `:in_process_sync` adapter (the `Behavior.CurlAgent` flavor pattern). This is a
  deliberate Phase-0 simplification for reliability inside the build time-box:
  the architecture (a Lifecycle agent driving an LLM → the Surface chokepoint) is
  faithful; folding the builder onto `Ezagent.Entity.Agent`'s curl-flavor
  AgentBridge transport is a clean follow-up. See the hello migration handoff.

  No durable state is needed in Phase 0 (the prompt is static, the API config
  comes from env), so `create/1` builds an empty `:hello_builder` slice and there
  are no transients.
  """

  use Ezagent.Lifecycle

  alias Ezagent.Message

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description: "Generate a page from an inbound user request"
  )

  # The builder Kind is `Ezagent.Entity.HelloBuilder` (type_name :hello_builder),
  # so the cap subject keys on the `:hello_builder` axis (mirrors echo's `:echo`).
  def required_caps do
    %{receive: Ezagent.Capability.cap(:hello_builder, __MODULE__, :receive)}
  end

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  @doc """
  On an inbound USER message, kick off page generation (fire-and-forget Task).
  Ignores non-user messages (other agents, its own output) so it never loops.
  Emits no effects — the generation result lands via the TurnDriver's dispatches.
  """
  def handle_receive(%{message: %Message{} = msg}, ctx) do
    with true <- from_user?(msg),
         %URI{} = session_uri <- session_from_ctx(ctx),
         text when is_binary(text) and text != "" <- extract_text(msg.body) do
      _ = EzagentPluginHello.Generator.start(session_uri, text)
    end

    {:ok, %{}, []}
  end

  # caps-data-ownership — admin-only Behavior; no per-entity owner.
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # --- internals --------------------------------------------------------

  # `Message.sender` is canonically a `%URI{}`; classify via the canonical type
  # accessor (`entity://user/…` → type `:user`) rather than a positional path
  # read (uri_query.scan invariant #11). A non-user / non-entity sender (another
  # agent, the builder's own output) → false, so generation never loops.
  defp from_user?(%Message{sender: %URI{} = uri}), do: Ezagent.URI.type?(uri, :user)
  defp from_user?(_), do: false

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  # For the session→member fan-out, ctx.caller is the originating session URI.
  defp session_from_ctx(%{caller: %URI{} = u}), do: u

  defp session_from_ctx(%{caller: s}) when is_binary(s) do
    try do
      Ezagent.URI.new!(s)
    rescue
      ArgumentError -> nil
    end
  end

  defp session_from_ctx(_), do: nil
end
