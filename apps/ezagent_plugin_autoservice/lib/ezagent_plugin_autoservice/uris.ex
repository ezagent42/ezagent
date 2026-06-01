defmodule EzagentPluginAutoservice.Uris do
  @moduledoc """
  Pure URI-derivation helpers for the autoservice vertical.

  Every customer-service entity is derived deterministically from the
  customer's User URI so the facade + seed + LiveViews all agree on
  names without a side table (P3 — the URI structure is the SoT):

      customer  entity://user/<ws>/<name>
      session   session://cs/<ws>/<name>
      fast      entity://agent/<ws>/curl_fast-<name>
      slow      entity://agent/<ws>/cc_slow-<name>

  `cs` is the session template-class segment (informational per
  `EzagentDomainChat.create_session/3` — segment 1 is not resolved
  against the TemplateRegistry).
  """

  @session_class "cs"

  @doc "The session template-class segment used for customer-service sessions."
  def session_class, do: @session_class

  @doc """
  `{workspace_name, customer_name}` from a customer User URI.

  Raises `ArgumentError` for any non `entity://user/<ws>/<name>` URI.
  """
  @spec decompose_customer(URI.t()) :: {String.t(), String.t()}
  def decompose_customer(%URI{scheme: "entity", host: "user", path: "/" <> rest})
      when rest != "" do
    case String.split(rest, "/", parts: 2) do
      [ws, name] when ws != "" and name != "" -> {ws, name}
      _ -> raise ArgumentError, "expected entity://user/<ws>/<name>, got path /#{rest}"
    end
  end

  def decompose_customer(other),
    do: raise(ArgumentError, "expected a customer User URI, got: #{inspect(other)}")

  @doc "Customer-service session URI for a customer: `session://cs/<ws>/<name>`."
  @spec session_uri(URI.t()) :: URI.t()
  def session_uri(%URI{} = customer_uri) do
    {ws, name} = decompose_customer(customer_uri)
    Ezagent.URI.new!("session://#{@session_class}/#{ws}/#{name}")
  end

  @doc "Fast (curl/DeepSeek) agent URI: `entity://agent/<ws>/curl_fast-<name>`."
  @spec fast_agent_uri(URI.t()) :: URI.t()
  def fast_agent_uri(%URI{} = customer_uri) do
    {ws, name} = decompose_customer(customer_uri)
    Ezagent.URI.new!("entity://agent/#{ws}/curl_fast-#{name}")
  end

  @doc "Slow (cc) agent URI: `entity://agent/<ws>/cc_slow-<name>`."
  @spec slow_agent_uri(URI.t()) :: URI.t()
  def slow_agent_uri(%URI{} = customer_uri) do
    {ws, name} = decompose_customer(customer_uri)
    Ezagent.URI.new!("entity://agent/#{ws}/cc_slow-#{name}")
  end

  @doc """
  The flavor `name` arg `Workspace.create_agent/3` expects (it composes
  `entity://agent/<ws>/<flavor>_<name>` itself). For the fast agent the
  flavor is `curl` and the name is `fast-<customer>`.
  """
  @spec fast_agent_create_name(URI.t()) :: String.t()
  def fast_agent_create_name(%URI{} = customer_uri) do
    {_ws, name} = decompose_customer(customer_uri)
    "fast-#{name}"
  end

  @spec slow_agent_create_name(URI.t()) :: String.t()
  def slow_agent_create_name(%URI{} = customer_uri) do
    {_ws, name} = decompose_customer(customer_uri)
    "slow-#{name}"
  end
end
