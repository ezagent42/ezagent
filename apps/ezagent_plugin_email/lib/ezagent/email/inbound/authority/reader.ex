defmodule Ezagent.Email.Inbound.Authority.Reader do
  @moduledoc false

  import Ecto.Query

  alias Ezagent.Email.InboundBinding
  alias Ezagent.ExternalMirror.BindingRow
  alias EzagentCore.Repo

  @doc false
  @spec read(String.t()) :: {InboundBinding.t(), BindingRow.t() | nil} | nil
  def read(local_address) when is_binary(local_address) do
    Repo.one(
      from(meta in InboundBinding,
        left_join: row in BindingRow,
        on: row.id == meta.binding_row_id,
        where: meta.local_address == ^local_address,
        select: {meta, row}
      )
    )
  end
end
