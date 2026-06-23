defmodule Ezagent.Email.Inbox do
  @moduledoc """
  Backend behaviour for reading inbound mail. `CFWorker` (HTTP pull from the
  Cloudflare Email Worker) is the only impl this round; an `Imap` backend is
  reserved (`backend: "imap"`).
  """
  @callback list(config :: map(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch(config :: map(), key :: String.t()) :: {:ok, map()} | {:error, term()}
  @callback delete(config :: map(), key :: String.t()) :: :ok | {:error, term()}
end
