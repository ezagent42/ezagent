defmodule EzagentPluginAutoservice.Uris do
  @moduledoc """
  Pure URI-derivation helpers for the autoservice vertical.

  Every customer-service entity is derived deterministically from the
  customer's User URI so the facade + seed + LiveViews all agree on
  names without a side table (P3 -- the URI structure is the SoT):

      customer  entity://<ws>/user/<name>
      session   session://<ws>/cs/<name>
      fast      entity://<ws>/agent/curl_fast-<name>
      slow      entity://<ws>/agent/cc_slow-<name>

  `cs` is the session template-class segment (informational per
  `EzagentDomainChat.create_session/3` -- segment 1 is not resolved
  against the TemplateRegistry).

  These URIs follow the 3-segment canonical form mandated by SPEC v3 §3
  (PR #159): `<scheme>://<workspace>/<type>/<name>`.
  """

  @session_class "cs"

  @doc "The session template-class segment used for customer-service sessions."
  def session_class, do: @session_class

  @doc """
  `{workspace_name, customer_name}` from a customer User URI.

  Extracts the workspace from the host and the name from the second
  path segment per the 3-segment entity URI format
  `entity://<workspace>/user/<name>`.

  Raises `ArgumentError` for any non `entity://<ws>/user/<name>` URI.
  """
  @spec decompose_customer(URI.t()) :: {String.t(), String.t()}
  def decompose_customer(%URI{scheme: "entity", host: ws, path: "/user/" <> rest})
      when ws != "" and rest != "" do
    name = String.trim_trailing(rest, "/")

    if name != "" do
      {ws, name}
    else
      raise ArgumentError,
            "expected entity://<ws>/user/<name>, got entity://#{ws}/user/#{rest} (empty name)"
    end
  end

  def decompose_customer(other),
    do: raise(ArgumentError, "expected a customer User URI, got: #{inspect(other)}")

  @doc "Customer-service session URI for a customer: `session://<ws>/cs/<name>`."
  @spec session_uri(URI.t()) :: URI.t()
  def session_uri(%URI{} = customer_uri) do
    {ws, name} = decompose_customer(customer_uri)
    Ezagent.URI.new!("session://#{ws}/#{@session_class}/#{name}")
  end

  @doc "Fast (curl/DeepSeek) agent URI: `entity://<ws>/agent/curl_fast-<name>`."
  @spec fast_agent_uri(URI.t()) :: URI.t()
  def fast_agent_uri(%URI{} = customer_uri) do
    {ws, name} = decompose_customer(customer_uri)
    Ezagent.URI.new!("entity://#{ws}/agent/curl_fast-#{name}")
  end

  @doc """
  Slow (cc) agent URI: `entity://<ws>/agent/slow-<name>`.

  MUST equal what `Workspace.create_agent` produces from
  `slow_agent_create_name/1`. `create_agent` composes the agent URI as
  `entity://<ws>/agent/<name>` (it does NOT prepend the flavor),
  so the URI here uses the bare `slow-<name>` create-name.
  A prior `cc_slow-<name>` value silently broke routing/join.
  Ported from PR #740.
  """
  @spec slow_agent_uri(URI.t()) :: URI.t()
  def slow_agent_uri(%URI{} = customer_uri) do
    {ws, name} = decompose_customer(customer_uri)
    Ezagent.URI.new!("entity://#{ws}/agent/slow-#{name}")
  end

  @doc """
  The flavor `name` arg `Workspace.create_agent/3` expects (it composes
  `entity://<ws>/agent/<flavor>_<name>` itself). For the fast agent the
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
