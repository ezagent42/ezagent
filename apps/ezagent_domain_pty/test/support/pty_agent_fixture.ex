defmodule EzagentDomainPty.Test.PtyAgentFixture do
  @moduledoc false

  alias EzagentDomainPty.Test.PtyAgentKind

  @spec spawn(URI.t()) :: {:ok, pid()} | {:error, term()}
  def spawn(%URI{} = uri) do
    :ok = Ezagent.BehaviorRegistry.register(PtyAgentKind, :write, Ezagent.ActionSet.Pty)

    case Ezagent.Kind.spawn(PtyAgentKind, %{uri: uri}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end
end
