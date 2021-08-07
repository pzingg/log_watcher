defmodule Translations do
  @moduledoc """
  Translations keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc """
  Traverse the errors in a Changeset and present each one as
  a sentence such as "Email can't be blank."
  """
  @spec changeset_error_messages(Ecto.Changeset.t()) :: [String.t()]
  def changeset_error_messages(changeset) do
    Ecto.Changeset.traverse_errors(changeset, &Translations.translate_error(&1))
    |> Enum.map(fn {field, errors} ->
      field_str = humanize_field(field) |> String.capitalize()
      Enum.map(errors, fn error -> field_str <> " " <> error <> "." end)
    end)
  end

  @doc """
  Interpolate the bindings (e.g. `%{count}`) of a Changeset error into
  an error message, using the plural message if a `%{count}` binding
  is included.
  """
  @spec translate_error({String.t(), Keyword.t()}) :: String.t()
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate "is invalid" in the "errors" domain
    #     dgettext("errors", "is invalid")
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # Because the error messages we show in our forms and APIs
    # are defined inside Ecto, we need to translate them dynamically.
    # This requires us to call the Gettext module passing our gettext
    # backend as first argument.
    #
    # Note we use the "errors" domain, which means translations
    # should be written to the errors.po file. The :count option is
    # set by Ecto and indicates we should also apply plural rules.
    if count = opts[:count] do
      Gettext.dngettext(Translations.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(Translations.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Interpolate the bindings (e.g. `%{count}`) of a Changeset error into
  an error message.
  """
  @spec translate_error_without_gettext({String.t(), Keyword.t()}) :: String.t()
  def translate_error_without_gettext({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  @doc """
  Use `gettext` to possibly customize a field name, then remove trailing
  "_id" strings and replace underscores with spaces.
  """
  @spec humanize_field(atom() | binary()) :: String.t()
  def humanize_field(atom) when is_atom(atom), do: humanize_field(Atom.to_string(atom))

  def humanize_field(bin) when is_binary(bin) do
    next_bin =
      Gettext.dgettext(Translations.Gettext, "fields", bin)
      |> String.trim_trailing("_id")

    Regex.replace(~r/_+/, next_bin, " ")
  end

  @doc """
  Copied from Phoenix.HTML module. Remove trailing "_id" string from a field
  name, and replace underscores with spaces.
  """
  @spec humanize_field_without_gettext(atom() | binary()) :: String.t()
  def humanize_field_without_gettext(atom) when is_atom(atom),
    do: humanize_field_without_gettext(Atom.to_string(atom))

  def humanize_field_without_gettext(bin) when is_binary(bin) do
    Regex.replace(~r/_+/, String.trim_trailing(bin, "_id"), " ")
  end
end
