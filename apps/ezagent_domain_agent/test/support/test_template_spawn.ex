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

      {:after_display_profile, {:fail_after_display_profile, owner}} ->
        send(owner, {:template_spawn_after_display_profile, completion, result})
        {:error, :injected_post_profile_failure}

      {:after_display_profile, {:fail_after_display_profile_gated, owner}} ->
        # #201-cred (codex r2 HIGH-3) — pause INSIDE the post-spawn
        # obligations (display profile inserted, failure not yet returned, so
        # rollback has NOT run) until the test releases the gate. The test
        # uses the pause to land a concurrent grant reapproval before the
        # rollback's credential-cleanup step.
        send(owner, {:template_spawn_after_display_profile_gated, completion, result, self()})

        receive do
          :release_display_profile_gate -> :ok
        end

        {:error, :injected_post_profile_failure}

      _ ->
        :ok
    end
  end
end
