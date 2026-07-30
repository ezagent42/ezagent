defmodule Ezagent.Cap.TokenSecret do
  @moduledoc """
  Shared reader for a core-owned, per-module token signing `secret_key_base`.

  Signed-token modules (`Ezagent.Uploads.DownloadToken`, `Ezagent.Cap.ShareToken`)
  each read their `Phoenix.Token` MAC key from
  `config :ezagent_core, <Module>, secret_key_base: <string>` (wired to the app
  secret). Centralising that read here keeps the token modules free of any
  `EzagentWeb.Endpoint` reference (three-tier layer boundary) and free of a
  duplicated key-loading body.
  """

  @doc """
  The `secret_key_base` configured for `module` — a `Phoenix.Token` MAC key.
  Raises with a config hint if it is unset or shorter than 20 bytes.
  """
  @spec key_base!(module()) :: binary()
  def key_base!(module) do
    case Application.get_env(:ezagent_core, module, []) |> Keyword.get(:secret_key_base) do
      base when is_binary(base) and byte_size(base) >= 20 ->
        base

      _ ->
        raise """
        no :secret_key_base configured for #{inspect(module)}.

        Add to config (wired to the same value as the web endpoint):

            config :ezagent_core, #{inspect(module)},
              secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
        """
    end
  end
end
