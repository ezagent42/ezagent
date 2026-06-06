defmodule Ezagent.Credential.GrantCap do
  @moduledoc """
  Derives the least-privilege source-read cap for a validated credential grant
  (spec §5.1, codex H1). The caller passes this SINGLE cap as the dispatch caps
  for the source read (`sandbox.read` on the source agent) — never a broad set.

  The materialize identity (`system://credential-materializer`) holds NO standing
  caps; all source-read authority is this narrow, per-source derived cap.
  """

  @doc """
  A narrow source-read cap scoped to exactly `source_uri`. The workspace MUST be
  derived the SAME way the dispatch derives it — `Ezagent.Capability.workspace_of/1`
  returns a `workspace://<ws>` URI, and `Capability.matches?/2` requires exact
  workspace-URI equality (codex: a raw `"team-a"` string would NOT match → read
  denied).

  Built as `Capability.cap(:agent, Ezagent.Behavior.Sandbox, :read, source, ws)`:
  `Ezagent.Behavior.Sandbox` serves the `:read` action on the Agent Kind
  (`required_caps[:read] = cap(:agent, Sandbox, :read)`), so this derived cap
  `matches?/2` the needed-cap the dispatch builds via
  `Capability.cap_for_action(<AgentKind>, :read, source)`.
  """
  @spec read_cap_for(URI.t()) :: Ezagent.Capability.t()
  def read_cap_for(%URI{} = source_uri) do
    # %URI{scheme: "workspace"} — the structural workspace of the source.
    ws_uri = Ezagent.Capability.workspace_of(source_uri)

    Ezagent.Capability.cap(:agent, Ezagent.Behavior.Sandbox, :read, source_uri, ws_uri)
  end
end
