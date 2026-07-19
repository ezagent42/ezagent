defmodule Ezagent.ProviderConnection.Test.FakeDriverBeta do
  @moduledoc false

  @behaviour Ezagent.ProviderConnection.Driver

  def declaration_metadata(extra \\ %{}) do
    Map.merge(extra, %{
      authorization_redirect_schema: %{
        type: :map,
        fields: %{
          "authorization_uri" => %{type: :string},
          "state" => %{type: :string},
          "pkce_digest" => %{type: :string}
        }
      },
      provider_metadata_schema: %{
        type: :map,
        fields: %{"class" => %{type: :string}}
      }
    })
  end

  @impl true
  def begin_authorization(context),
    do: {:ok, %{flow: "device", context: context}}

  @impl true
  def consume_callback(context),
    do: {:ok, %{external_account: %{tenant: "beta-tenant", member: "beta-member"}, metadata: %{class: "beta"}, context: context}}

  @impl true
  def refresh(context),
    do: {:ok, %{refresh: %{rotation: "conditional", generations: 2}, context: context}}

  @impl true
  def revoke(context),
    do: {:ok, %{revocation: %{mode: "credential-first", receipts: true}, context: context}}
end
