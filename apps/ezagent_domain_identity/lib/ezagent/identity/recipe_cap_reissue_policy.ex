defmodule Ezagent.Identity.RecipeCapReissuePolicy do
  @moduledoc false

  @behaviour Ezagent.Cap.ReissuePolicy

  alias Ezagent.Capability

  @impl true
  def classify(%Capability{kind: :agent}), do: {:ok, :agent_recipe_candidate}
  def classify(_cap), do: :not_mine

  @impl true
  def reissue_action(%Capability{} = cap, %URI{} = receiver_uri) do
    {:refresh_binding,
     %{
       agent_uri: Ezagent.URI.instance(receiver_uri),
       cap_identity: Capability.identity_key(cap)
     }}
  end
end
