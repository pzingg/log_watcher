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
      Enum.map(errors, fn error ->
        Translations.humanize_field(field) <> " " <> error <> "."
      end)
    end)
  end

  @doc """
  Interpolate the bindings (e.g. `%{count}`) of a Changeset error into
  an error message, using the plural message if a `%{count}` binding
  is included.
  """
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
  Copied from Phoenix.HTML module. Upcase a field name (either an
  atom or a string), changing underscores to spaces and removing
  any "_id" suffix.
  """
  @spec humanize_field(atom() | binary()) :: String.t()
  def humanize_field(atom) when is_atom(atom), do: humanize_field(Atom.to_string(atom))

  def humanize_field(bin) when is_binary(bin) do
    bin =
      if String.ends_with?(bin, "_id") do
        binary_part(bin, 0, byte_size(bin) - 3)
      else
        bin
      end

    Gettext.dgettext(Translations.Gettext, "fields", bin)
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
