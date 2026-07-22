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

  action(:rebuild,
    args: %{session_uri: :string, instruction: :string},
    returns: %{},
    caps: [:rebuild],
    modes: [:cast],
    description: "Regenerate the hello page for the target session"
  )

  # No hand-written `required_caps`: this behavior now runs on the unified
  # `Ezagent.Entity.Agent` (as a `hello.builder` role on the `native` flavor), so
  # the Lifecycle macro derives the `:receive` / `:rebuild` caps on the `:agent`
  # axis — the axis the role's minted caps use (RoleStep mints `kind: :agent`).
  # Mirrors the kanban role behavior, which likewise declares only the `action/3`
  # `caps:`.

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
      _ = generator_start(session_uri, text)
    end

    {:ok, %{}, []}
  end

  @doc """
  Dispatchable rebuild entry for native hello builders.

  Chat delivery to native members intentionally stops at `agent.receive` →
  `AgentBridge`; callers that want the deterministic builder to act must dispatch
  this named action with the matching caller-held cap.
  """
  def handle_rebuild(args, ctx) when is_map(args) and is_map(ctx) do
    with {:ok, session_uri} <- rebuild_session_uri(args),
         {:ok, instruction} <- rebuild_instruction(args),
         :ok <- ensure_self_member(session_uri, ctx) do
      _ = generator_start(session_uri, instruction)
      {:ok, %{}, []}
    end
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

  defp rebuild_session_uri(args) do
    case Map.get(args, :session_uri) || Map.get(args, "session_uri") do
      %URI{} = uri ->
        {:ok, uri}

      uri when is_binary(uri) ->
        {:ok, Ezagent.URI.new!(uri)}

      _ ->
        {:error, :invalid_rebuild_args}
    end
  rescue
    ArgumentError -> {:error, :invalid_rebuild_args}
  end

  defp rebuild_instruction(args) do
    case Map.get(args, :instruction) || Map.get(args, "instruction") do
      instruction when is_binary(instruction) ->
        instruction = String.trim(instruction)
        if instruction == "", do: {:error, :invalid_rebuild_args}, else: {:ok, instruction}

      _ ->
        {:error, :invalid_rebuild_args}
    end
  end

  defp ensure_self_member(%URI{} = session_uri, %{self_uri: %URI{} = self_uri}) do
    case Ezagent.Session.Membership.authorize(%{}, self_uri, session_uri, self_uri) do
      :ok -> :ok
      {:error, :unauthorized} -> {:error, {:builder_not_session_member, session_uri, self_uri}}
    end
  end

  defp ensure_self_member(_session_uri, _ctx), do: {:error, :missing_builder_uri}

  defp generator_start(%URI{} = session_uri, instruction) when is_binary(instruction) do
    :ezagent_plugin_hello
    |> Application.get_env(:generator_start, &EzagentPluginHello.Generator.start/2)
    |> then(& &1.(session_uri, instruction))
  end

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
