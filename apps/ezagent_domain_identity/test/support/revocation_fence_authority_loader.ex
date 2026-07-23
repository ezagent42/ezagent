defmodule Ezagent.Identity.Test.RevocationFenceAuthorityLoader do
  @behaviour Ezagent.Cap.AuthorityLoader

  @impl true
  def read_held_caps(_holder) do
    Application.get_env(:ezagent_domain_identity, __MODULE__, MapSet.new())
  end

  @impl true
  def principal_fenced?(holder) do
    Ezagent.Identity.Offboarding.RevocationFence.fenced?(holder)
  end
end
