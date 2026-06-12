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
      Ezagent.Behavior.Surface,
      # P0 (socialware substrate) — every SocialwareSession composes the
      # Publisher trunk. `SessionImpl` owns the `:publisher` slice and the
      # slice-change recording. NO consumer change in P0: the slice simply
      # exists + records now. The publisher READ API (snapshot/history/
      # subscribe_from dispatch) and its cap boundary are wired in P3
      # (ExternalAdapter consumer) — see the spec/plan deferral note.
      Ezagent.Behavior.Publisher.SessionImpl
    ]
  end

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  # P5-0b (socialware substrate collapse) — every SocialwareSession instance
  # MUST carry an explicit (non-nil) `:kind_base` behavior set; a nil capture
  # fails loud in `BehaviorSet.effective_set/2`. Scoped to the session Kind(s).
  @impl Ezagent.Kind
  def requires_explicit_behavior_set?, do: true

  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainSocialware.SocialwareSessionSupervisor
end
