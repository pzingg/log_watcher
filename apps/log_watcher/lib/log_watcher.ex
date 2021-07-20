defmodule LogWatcher do
  @moduledoc """
  LogWatcher keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  ### Changeset utilities

  defmodule InputError do
    defexception [:message]

    @impl true
    def exception(message) do
      %__MODULE__{message: message}
    end
  end

  @type normalized_result() :: {:ok, struct()} | {:error, Ecto.Changeset.t()}

  @spec raise_input_error(normalized_result(), String.t(), atom()) :: struct()
  def raise_input_error({:error, changeset}, label, id_field) do
    id_value = Ecto.Changeset.get_field(changeset, id_field)
    errors = input_error_messages(changeset) |> Enum.join(" ")

    message =
      if !is_nil(id_value) do
        "#{label} (id: #{id_value}): #{errors}"
      else
        "#{label}: #{errors}"
      end

    raise InputError, message
    InputError.exception(message)
  end

  def raise_input_error({:ok, data}, _label, _id_field), do: data

  @spec input_error_messages(Ecto.Changeset.t()) :: [String.t()]
  def input_error_messages(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} ->
      Enum.map(errors, fn error ->
        humanize(field) <> " " <> error <> "."
      end)
    end)
  end

  @doc """
  Copied from Phoenix.HTML module.
  """
  # TODO: Use Gettext to rewrite field names?
  # Will require access to Gettext modules in each application?
  @spec humanize(atom() | binary()) :: String.t()
  def humanize(atom) when is_atom(atom), do: humanize(Atom.to_string(atom))

  def humanize(bin) when is_binary(bin) do
    bin =
      if String.ends_with?(bin, "_id") do
        binary_part(bin, 0, byte_size(bin) - 3)
      else
        bin
      end

    bin |> String.replace("_", " ") |> String.capitalize()
  end

  @doc """
  Parse Absinthe-like schema definition for schemaless changesets.
  The schema is a map of `{field, type}` items,
  The `type` can be any Ecto field type, or can be a list, where
  the first element is the Ecto field type, and the remaining elements
  are keyword options. The only recognized option is `:required`.

  Returns a 3-tuple, with these elements:
    * the cleaned `{field, type}` map
    * a list of all the field names (atoms)
    * a list of only the field names with the `:required` option
  """
  @spec parse_input_types(map()) :: {map(), [atom()], [atom()]}
  def parse_input_types(input_schema) do
    parsed =
      Enum.map(input_schema, fn
        {k, nil} ->
          raise "invalid schema at #{k}"

        {k, v} when is_atom(v) or is_tuple(v) ->
          [{k, v}, k, nil]

        {k, v} when is_list(v) ->
          [type | opts] = v

          if is_atom(type) or is_tuple(type) do
            if Keyword.get(opts, :required, false) do
              [{k, type}, k, k]
            else
              [{k, type}, k, nil]
            end
          else
            raise "invalid schema at #{k}"
          end
      end)
      |> List.zip()

    [types, permitted_fields, required_fields] = parsed

    {
      Tuple.to_list(types) |> Map.new(),
      Tuple.to_list(permitted_fields),
      Tuple.to_list(required_fields) |> Enum.filter(fn k -> !is_nil(k) end)
    }
  end
end
