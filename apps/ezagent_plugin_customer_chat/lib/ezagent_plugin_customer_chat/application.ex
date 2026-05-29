defmodule EzagentPluginCustomerChat.Application do
  @moduledoc """
  Customer-chat plugin OTP application — the `Ezagent.Plugin` contract
  module (the AI-customer-service template's frontend slice).

  Ships UI + bootstrap logic only: the public customer chat LiveView +
  widget logic, and the operator console. It declares NO Kinds /
  Behaviors / agent flavors / templates — the generic takeover
  primitive (`Ezagent.Behavior.Mode`) lives in `ezagent_domain_chat`.

  `config_surface/0` is a `:route` to `/operator`, so the `/plugins`
  card links straight to the operator console. `adapters/0` is left
  empty but reserved — it is the future home for a foreign-IM
  External Mirror adapter (e.g. CINNOX); see
  `poc/phase-2/10-customer-chat-plugin-extraction-design.md` §7.
  """

  use Application
  use Ezagent.Plugin

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract -----------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "customer_chat",
      name: "Customer Service",
      description: "AI customer service — web chat, embeddable widget, operator takeover.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :route, path: "/operator", label: "Customer Service"}
  end
end
