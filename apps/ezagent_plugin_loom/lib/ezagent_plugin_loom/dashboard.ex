defmodule EzagentPluginLoom.Dashboard do
  @moduledoc """
  Loom **operator 控制台**数据(清单 A,operator-only)。聚合 per-session 运营视图:
  token/调用(`Stats`,telemetry 累计)+ 素材数(`Materials`)+ 知识库字节(`Knowledge`)。
  纯数据聚合(后端);operator HEEx UI 是前端层(见 PR 说明)。
  """

  alias EzagentPluginLoom.{Knowledge, Materials, Stats}

  @doc "session 运营摘要。"
  @spec summary(URI.t()) :: map()
  def summary(%URI{} = session_uri) do
    stats = Stats.get(session_uri)

    %{
      tokens: %{input: stats.input, output: stats.output, total: stats.input + stats.output},
      calls: stats.calls,
      materials: length(Materials.list(session_uri)),
      knowledge_bytes: byte_size(Knowledge.get(session_uri) || "")
    }
  end
end
