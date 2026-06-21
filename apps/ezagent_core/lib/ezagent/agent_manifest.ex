defmodule Ezagent.AgentManifest do
  @moduledoc """
  Declarative agent definition contract.

  `AgentManifest` is the data form for an agent body: backend-agnostic
  author fields plus an executor binding that selects one or more runtime
  flavors. It is loaded and validated before spawn-time rendering.
  """

  @type executor :: %{
          required(:flavor) => [String.t()],
          required(:params) => map(),
          required(:fallback) => [map()] | nil,
          required(:on_exhausted) => :notify_orchestrator
        }

  @type t :: %__MODULE__{
          name: String.t(),
          soul: String.t(),
          skills: [String.t()],
          tools: [map()],
          caps: [map() | Ezagent.Capability.t()],
          lifecycle: :persistent | :ephemeral,
          executor: executor()
        }

  defstruct name: nil,
            soul: nil,
            skills: [],
            tools: [],
            caps: [],
            lifecycle: :persistent,
            executor: nil

  @slot_re ~r/{{\s*([A-Za-z0-9_.-]+)\s*}}/
  @forbidden_author_fields [:flavor, :derived_config, :compiled_config]

  @doc """
  Load and validate an agent manifest from a map or YAML string.
  """
  @spec load(map() | String.t()) :: {:ok, t()} | {:error, term()}
  def load(yaml) when is_binary(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{} = map} -> load(map)
      {:ok, other} -> {:error, {:invalid_manifest_yaml, other}}
      {:error, reason} -> {:error, {:invalid_manifest_yaml, reason}}
    end
  rescue
    exception -> {:error, {:invalid_manifest_yaml, exception}}
  end

  def load(%{} = map) do
    with :ok <- reject_forbidden_author_fields(map),
         {:ok, name} <- required_string(map, :name),
         {:ok, soul} <- required_string(map, :soul),
         {:ok, skills} <- string_list(map, :skills, []),
         {:ok, tools} <- map_list(map, :tools, []),
         {:ok, caps} <- list_field(map, :caps, []),
         {:ok, lifecycle} <- lifecycle(map),
         {:ok, executor} <- executor(map) do
      {:ok,
       %__MODULE__{
         name: name,
         soul: soul,
         skills: skills,
         tools: tools,
         caps: caps,
         lifecycle: lifecycle,
         executor: executor
       }}
    end
  end

  def load(other), do: {:error, {:invalid_manifest, other}}

  @doc """
  Render a soul template with slot values.

  Missing slots fail loud; rendered instructions are a derived spawn-time
  artifact and are not written back into the manifest.
  """
  @spec render(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def render(soul_template, slots) when is_binary(soul_template) and is_map(slots) do
    slot_names =
      @slot_re
      |> Regex.scan(soul_template, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    case resolve_slots(slot_names, slots) do
      {:ok, slot_values} ->
        rendered =
          Regex.replace(@slot_re, soul_template, fn _full, name ->
            Map.fetch!(slot_values, name)
          end)

        {:ok, rendered}

      {:error, _reason} = error ->
        error
    end
  end

  def render(_soul_template, _slots), do: {:error, :invalid_render_args}

  @doc """
  Build transient AgentTemplate content for a single executor candidate.

  The returned map is the bridge into the existing spawn path. It carries
  manifest-derived data only for this spawn attempt; it must not be persisted as
  the manifest body.
  """
  @spec to_template_content(t(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def to_template_content(manifest, flavor, slots, candidate_params \\ %{})

  def to_template_content(%__MODULE__{} = manifest, flavor, slots, candidate_params)
      when is_binary(flavor) and is_map(slots) and is_map(candidate_params) do
    params = Map.merge(manifest.executor.params, candidate_params)

    with :ok <- ensure_candidate_flavor(manifest, flavor),
         {:ok, instructions} <- render(manifest.soul, slots),
         {:ok, project_cwd} <- required_param(params, :project_cwd) do
      resolved = %{
        name: manifest.name,
        instructions: instructions,
        skills: manifest.skills,
        tools: manifest.tools,
        caps: manifest.caps,
        lifecycle: manifest.lifecycle
      }

      content =
        %{
          flavor: flavor,
          project_cwd: project_cwd,
          desired_skills: manifest.skills,
          desired_caps: manifest.caps,
          agent_manifest_resolved: resolved,
          agent_manifest_params: params
        }
        |> put_optional_param(:config_dir, params)

      {:ok, content}
    end
  end

  def to_template_content(_manifest, _flavor, _slots, _candidate_params),
    do: {:error, :invalid_template_content_args}

  defp ensure_candidate_flavor(%__MODULE__{} = manifest, flavor) do
    if flavor in manifest.executor.flavor do
      :ok
    else
      {:error, {:executor_flavor_not_declared, flavor}}
    end
  end

  defp required_param(params, key) when is_map(params) and is_atom(key) do
    case param(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_executor_param, key}}
    end
  end

  defp put_optional_param(content, key, params) when is_atom(key) do
    case param(params, key) do
      value when is_binary(value) and value != "" -> Map.put(content, key, value)
      _ -> content
    end
  end

  defp param(params, key) when is_atom(key) do
    Map.get(params, Atom.to_string(key)) || Map.get(params, key)
  end

  defp resolve_slots(slot_names, slots) do
    Enum.reduce_while(slot_names, {:ok, %{}}, fn name, {:ok, acc} ->
      case fetch_slot(slots, name) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        {:error, _reason} = error -> {:halt, error}
        :error -> {:halt, {:error, {:missing_slot, name}}}
      end
    end)
  end

  defp reject_forbidden_author_fields(map) do
    Enum.find_value(@forbidden_author_fields, :ok, fn field ->
      if has_key?(map, field), do: {:error, {:author_field_forbidden, field}}, else: nil
    end)
  end

  defp executor(map) do
    case fetch_key(map, :executor) do
      {:ok, %{} = raw} ->
        with {:ok, flavors} <- executor_flavors(raw),
             {:ok, params} <- map_field(raw, :params, %{}),
             {:ok, fallback} <- fallback(raw),
             {:ok, on_exhausted} <- on_exhausted(raw) do
          {:ok,
           %{
             flavor: flavors,
             params: params,
             fallback: fallback,
             on_exhausted: on_exhausted
           }}
        end

      {:ok, other} ->
        {:error, {:invalid_executor, other}}

      :error ->
        {:error, {:missing_required, :executor}}
    end
  end

  defp executor_flavors(raw) do
    case fetch_key(raw, :flavor) do
      {:ok, value} ->
        value
        |> List.wrap()
        |> Enum.reduce_while([], fn
          flavor, acc when is_binary(flavor) and flavor != "" ->
            {:cont, [flavor | acc]}

          flavor, acc when is_atom(flavor) ->
            {:cont, [Atom.to_string(flavor) | acc]}

          bad, _acc ->
            {:halt, {:error, {:invalid_executor_flavor, bad}}}
        end)
        |> case do
          {:error, _} = err -> err
          [] -> {:error, :empty_executor_flavor}
          flavors -> {:ok, Enum.reverse(flavors)}
        end

      :error ->
        {:error, :empty_executor_flavor}
    end
  end

  defp fallback(raw) do
    case fetch_key(raw, :fallback) do
      {:ok, nil} -> {:ok, nil}
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, other} -> {:error, {:invalid_fallback, other}}
      :error -> {:ok, nil}
    end
  end

  defp on_exhausted(raw) do
    case fetch_key(raw, :on_exhausted) do
      {:ok, value} when value in ["notify_orchestrator", :notify_orchestrator] ->
        {:ok, :notify_orchestrator}

      {:ok, other} ->
        {:error, {:invalid_on_exhausted, other}}

      :error ->
        {:ok, :notify_orchestrator}
    end
  end

  defp lifecycle(map) do
    case get_key(map, :lifecycle, "persistent") do
      value when value in ["persistent", :persistent] -> {:ok, :persistent}
      value when value in ["ephemeral", :ephemeral] -> {:ok, :ephemeral}
      other -> {:error, {:invalid_lifecycle, other}}
    end
  end

  defp required_string(map, key) do
    case fetch_key(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, other} -> {:error, {:invalid_required, key, other}}
      :error -> {:error, {:missing_required, key}}
    end
  end

  defp string_list(map, key, default) do
    with {:ok, values} <- list_field(map, key, default) do
      Enum.reduce_while(values, {:ok, []}, fn
        value, {:ok, acc} when is_binary(value) -> {:cont, {:ok, [value | acc]}}
        other, _acc -> {:halt, {:error, {:invalid_list_item, key, other}}}
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        {:error, _} = err -> err
      end
    end
  end

  defp map_list(map, key, default) do
    with {:ok, values} <- list_field(map, key, default) do
      Enum.reduce_while(values, {:ok, []}, fn
        value, {:ok, acc} when is_map(value) -> {:cont, {:ok, [value | acc]}}
        other, _acc -> {:halt, {:error, {:invalid_list_item, key, other}}}
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        {:error, _} = err -> err
      end
    end
  end

  defp list_field(map, key, default) do
    case get_key(map, key, default) do
      values when is_list(values) -> {:ok, values}
      other -> {:error, {:invalid_list, key, other}}
    end
  end

  defp map_field(map, key, default) do
    case get_key(map, key, default) do
      value when is_map(value) -> {:ok, value}
      other -> {:error, {:invalid_map, key, other}}
    end
  end

  defp has_key?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp fetch_key(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.fetch!(map, Atom.to_string(key))}
      true -> :error
    end
  end

  defp get_key(map, key, default) do
    case fetch_key(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp fetch_slot(slots, name) do
    cond do
      Map.has_key?(slots, name) ->
        scalar_slot(Map.fetch!(slots, name), name)

      atom_key = existing_atom_key(slots, name) ->
        scalar_slot(Map.fetch!(slots, atom_key), name)

      true ->
        :error
    end
  end

  defp existing_atom_key(slots, name) do
    Enum.find(Map.keys(slots), fn
      key when is_atom(key) -> Atom.to_string(key) == name
      _key -> false
    end)
  end

  defp scalar_slot(value, _name) when is_binary(value), do: {:ok, value}
  defp scalar_slot(value, _name) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp scalar_slot(value, _name) when is_float(value), do: {:ok, Float.to_string(value)}
  defp scalar_slot(value, _name) when is_boolean(value), do: {:ok, to_string(value)}
  defp scalar_slot(value, name), do: {:error, {:invalid_slot_value, name, value}}
end
