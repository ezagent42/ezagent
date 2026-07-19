defmodule Ezagent.ProviderConnection.Test.FakeDriverAlpha do
  @moduledoc false

  @behaviour Ezagent.ProviderConnection.Driver

  @impl true
  def begin_authorization(context),
    do: {:ok, %{flow: "redirect", context: context}}

  @impl true
  def consume_callback(context),
    do: {:ok, %{external_account: %{subject: "alpha-subject"}, metadata: %{tier: "alpha"}, context: context}}

  @impl true
  def refresh(context),
    do: {:ok, %{refresh: %{rotation: "always"}, context: context}}

  @impl true
  def revoke(context),
    do: {:ok, %{revocation: %{mode: "provider-first"}, context: context}}
end
