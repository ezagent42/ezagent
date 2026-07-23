defmodule Ezagent.DomainGit.TestSupport.BootCallbackBomb do
  @behaviour Ezagent.DomainGit.Adapter

  for {name, arity} <- Ezagent.DomainGit.Adapter.behaviour_info(:callbacks) do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl true
    def unquote(name)(unquote_splicing(args)), do: raise("adapter callback executed during boot")
  end
end
