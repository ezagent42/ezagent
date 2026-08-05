defmodule Ezagent.Test.TemplateOptionsSessionClass do
  @moduledoc false
  @behaviour Ezagent.Kind.Template

  @impl true
  def template_name, do: "session.template-options-test"

  @impl true
  def instantiate(name, template, workspace_uri) do
    instantiate(name, template, workspace_uri, [])
  end

  @impl true
  def instantiate(_name, template, workspace_uri, _opts) do
    send(Application.fetch_env!(:ezagent_domain_workspace, :template_options_test_pid), {
      :template_options,
      template
    })

    session_uri =
      Ezagent.URI.session(
        Ezagent.URI.workspace_name!(workspace_uri),
        "template-options-test",
        Map.fetch!(template, "session_name")
      )

    _authority = Ezagent.Test.CapHelper.install_test_authority!(session_uri, :session)
    {:ok, [session_uri], %{fresh?: true}}
  end
end
