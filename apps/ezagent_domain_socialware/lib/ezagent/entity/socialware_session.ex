defmodule Ezagent.Entity.SocialwareSession do
  @moduledoc """
  Socialware session Kind.

  P1 composes Chat with the Turn state machine. Surface and publisher
  behavior are added in later phases as their contracts land.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :session

  @impl Ezagent.Kind
  def behaviors do
    [
      Ezagent.Behavior.Chat,
      Ezagent.Behavior.Turn,
      Ezagent.Behavior.Surface
    ]
  end

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainSocialware.SocialwareSessionSupervisor
end
