defmodule Ezagent.PluginNp.Test.MockDeepSeek do
  @moduledoc """
  Minimal `Plug.Router` mock for the DeepSeek `/chat/completions` API,
  spun up by the comprehensive 4-agent e2e via Bandit on a free port.

  The real curl-agent's `Ezagent.PluginCurlAgent.ApiClient` POSTs the
  OpenAI-shape `{model, messages}` payload here; this mock inspects the
  LAST user message (where the LaTeX from the fake-cc-agent lives) and
  returns a deterministic "numpy expression" reply.

  Transformation rule (deterministic, no LLM):
    * if any user message contains `\\int_0^1 x dx` → return `"0.5"`
      (the actual value of that integral — np-agent computes the same)
    * if any user message contains `\\latex{...}` wrapping plain
      arithmetic → strip the wrapper + return the arithmetic verbatim
      (np-agent's `compute` will evaluate it)
    * otherwise → return `"2 + 2"` (safe default; np yields 4)

  Returns the OpenAI completion shape so the curl-agent's response
  parser is exercised:

      {
        "choices": [{"message": {"content": "<numpy expr>"}}],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
      }
  """

  use Plug.Router

  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :match
  plug :dispatch

  post "/chat/completions" do
    user_message = pick_last_user_message(conn.body_params["messages"] || [])
    numpy_expr = transform_to_numpy(user_message)

    body =
      Jason.encode!(%{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => numpy_expr}}
        ],
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 5,
          "total_tokens" => 15
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp pick_last_user_message(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn m -> m["role"] == "user" end)
    |> case do
      %{"content" => c} when is_binary(c) -> c
      _ -> ""
    end
  end

  defp pick_last_user_message(_), do: ""

  # Public for test inspection if needed.
  @doc false
  def transform_to_numpy(text) when is_binary(text) do
    cond do
      String.contains?(text, "\\int_0^1 x") ->
        # The fake-cc-agent's hardcoded integral → its actual value.
        "0.5"

      true ->
        # Strip a leading `\latex{...}` wrapper, take what's inside.
        case Regex.run(~r/\\latex\{([^}]+)\}/, text) do
          [_, inner] -> String.trim(inner) |> default_if_empty()
          nil -> "2 + 2"
        end
    end
  end

  defp default_if_empty(""), do: "2 + 2"
  defp default_if_empty(s), do: s
end
