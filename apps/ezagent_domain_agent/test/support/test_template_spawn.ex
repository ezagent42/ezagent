defmodule Ezagent.Agent.TestTemplateSpawn do
  @moduledoc false

  def inject(instruction, owner) do
    :persistent_term.put({__MODULE__, :instruction}, {instruction, owner})
  end

  def clear do
    :persistent_term.erase({__MODULE__, :instruction})
  end

  def hook(stage, completion, result) do
    case {stage, :persistent_term.get({__MODULE__, :instruction}, nil)} do
      {:before_complete, {:barrier_before_complete, owner}} ->
        send(owner, {:template_spawn_before_complete, completion, result, self()})

        receive do
          :release_template_complete -> :ok
        end

      _ ->
        :ok
    end
  end
end
