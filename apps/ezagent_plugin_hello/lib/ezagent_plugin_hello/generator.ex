defmodule EzagentPluginHello.Generator do
  @moduledoc """
  Runs one page-generation turn for the hello builder, off the Behavior's
  GenServer process (so the slow LLM round-trip never blocks dispatch).

  `start/2` spawns a supervised Task (under `EzagentPluginHello.TaskSupervisor`);
  `generate/2`:

    1. calls the LLM (`LLM.ApiClient`) with the page-gen system prompt + the
       user's request;
    2. extracts the `@json-render` JSON spec from the reply (`Spec.extract/1`);
    3. validates it against the catalog (`Spec.validate/1` — out-of-catalog =
       fail-closed, no page);
    4. drives `TurnDriver.drive/3` to land the spec in `Surface` (the chokepoint).

  ## API config (Phase 0)

  The provider config comes from env (`HELLO_LLM_API_KEY` | `DEEPSEEK_KEY`,
  `HELLO_LLM_API_URL`, `HELLO_LLM_MODEL`), defaulting to DeepSeek. Storing the
  key on the agent's `:api_keys` slice (the curl-agent model) is a follow-up.
  """

  require Logger

  alias EzagentPluginHello.{Prompts, Spec, TurnDriver}
  alias EzagentPluginHello.LLM.ApiClient

  @doc "Spawn a supervised Task that generates + lands a page for `user_text`."
  @spec start(URI.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def start(%URI{} = session_uri, user_text) when is_binary(user_text) do
    Task.Supervisor.start_child(EzagentPluginHello.TaskSupervisor, fn ->
      generate(session_uri, user_text)
    end)
  end

  @doc "Generate a page spec from `user_text` and land it on `session_uri`'s Surface."
  @spec generate(URI.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(%URI{} = session_uri, user_text) when is_binary(user_text) do
    with {:ok, %{content: content}} <- call_llm(user_text),
         {:ok, raw_spec} <- Spec.extract(content),
         {:ok, spec} <- Spec.validate(raw_spec) do
      summary = page_summary(spec)
      TurnDriver.drive(session_uri, spec, summary)
    else
      {:error, reason} = err ->
        Logger.warning("hello.Generator: generation failed: #{inspect(reason)}")
        err
    end
  end

  defp call_llm(user_text) do
    case api_key() do
      key when is_binary(key) and key != "" ->
        ApiClient.chat_completion(%{
          api_url: api_url(),
          api_key: key,
          model: model(),
          messages: [
            %{role: "system", content: Prompts.page_gen_system()},
            %{role: "user", content: user_text}
          ]
        })

      _ ->
        {:error, :no_api_key}
    end
  end

  # A short customer-visible chat line announcing the new page (the page title
  # if present, else generic).
  defp page_summary(%{"props" => %{"title" => title}}) when is_binary(title) and title != "",
    do: "Generated page: #{title}"

  defp page_summary(_), do: "Generated your page."

  defp api_key, do: System.get_env("HELLO_LLM_API_KEY") || System.get_env("DEEPSEEK_KEY")

  defp api_url,
    do: System.get_env("HELLO_LLM_API_URL") || "https://api.deepseek.com/chat/completions"

  defp model, do: System.get_env("HELLO_LLM_MODEL") || "deepseek-chat"
end
