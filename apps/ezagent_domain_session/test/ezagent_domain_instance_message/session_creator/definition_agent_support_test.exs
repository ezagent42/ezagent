defmodule EzagentDomainInstanceMessage.SessionCreator.DefinitionAgentSupportTest do
  use ExUnit.Case, async: false

  alias Ezagent.AgentFlavorRegistry
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgentSupport

  test "a registered flavor with an invalid credential descriptor fails closed" do
    flavor = "invalid-credential-descriptor-#{System.unique_integer([:positive])}"

    unavailable_template =
      Module.concat([
        EzagentDomainInstanceMessage,
        SessionCreator,
        DefinitionAgentSupportTest,
        "UnavailableTemplate#{System.unique_integer([:positive])}"
      ])

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: unavailable_template
      })

    assert DefinitionAgentSupport.credential_admission_of(%{
             flavor: flavor,
             credential_admission: :immediate
           }) == :before_session_join
  end
end
