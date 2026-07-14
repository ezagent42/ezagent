defmodule EzagentWeb.HelloDelegationContinuation do
  @moduledoc """
  Signed, short-lived continuation for an anonymous hello-to-Kanban request.

  Authority is deliberately absent from the token. The authenticated principal
  is recovered from the browser session only after login.
  """

  @salt "hello Kanban delegation v1"
  @default_max_age 600
  @max_instruction 500

  @doc "Sign a hello session and bounded instruction with a fresh nonce."
  @spec sign(URI.t(), String.t()) :: String.t()
  def sign(%URI{scheme: "session"} = session_uri, instruction) when is_binary(instruction) do
    instruction = instruction |> String.trim() |> String.slice(0, @max_instruction)

    if hello_session?(session_uri) and instruction != "" do
      Phoenix.Token.sign(EzagentWeb.Endpoint, @salt, %{
        "session_uri" => uri_to_string(session_uri),
        "instruction" => instruction,
        "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      })
    else
      raise ArgumentError, "expected a hello session and non-empty instruction"
    end
  end

  @doc "Verify a continuation and recover only its non-authoritative request data."
  @spec verify(term()) ::
          {:ok, %{session_uri: URI.t(), instruction: String.t(), nonce: String.t()}}
          | {:error, :invalid_token}
  def verify(token) when is_binary(token) do
    with {:ok, payload} <-
           Phoenix.Token.verify(EzagentWeb.Endpoint, @salt, token, max_age: max_age()),
         %{"session_uri" => session_str, "instruction" => instruction, "nonce" => nonce}
         when is_binary(session_str) and is_binary(instruction) and is_binary(nonce) <- payload,
         {:ok, %URI{scheme: "session"} = session_uri} <- Ezagent.URI.parse(session_str),
         true <- hello_session?(session_uri),
         instruction <- instruction |> String.trim() |> String.slice(0, @max_instruction),
         true <- instruction != "" and byte_size(nonce) >= 16 do
      {:ok, %{session_uri: session_uri, instruction: instruction, nonce: nonce}}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def verify(_token), do: {:error, :invalid_token}

  defp hello_session?(session_uri) do
    match?({:ok, "hello"}, Ezagent.URI.type(session_uri))
  end

  defp max_age,
    do: Application.get_env(:ezagent_web, :hello_delegation_max_age, @default_max_age)

  defp uri_to_string(uri), do: URI.to_string(uri)
end
