defmodule ExAtlas.S3.XML do
  @moduledoc false

  # S3 answers in XML. OTP's SAX parser reads it without a new dependency, and
  # unlike `:xmerl_scan` it creates no atoms from element names, so a hostile
  # store cannot fill the atom table. `disallow_entities` refuses any entity
  # declaration, so nothing expands and no external file or URL is read.

  @type element :: {String.t(), [element() | String.t()]}

  @doc "Parse `xml` into `{name, children}`, where a child is an element or text."
  @spec parse(binary()) :: {:ok, element()} | :error
  def parse(xml) when is_binary(xml) and xml != "" do
    opts = [
      :disallow_entities,
      :skip_external_dtd,
      {:external_entities, :none},
      {:discard_ws_before_xml_document, true},
      {:event_fun, &event/3},
      {:event_state, [{"", []}]}
    ]

    case :xmerl_sax_parser.stream(xml, opts) do
      {:ok, [{"", [root]}], _rest} -> {:ok, root}
      _other -> :error
    end
  catch
    # The parser throws for some malformed input; the reason can quote it.
    _kind, _reason -> :error
  end

  def parse(_other), do: :error

  defp event({:startElement, _uri, name, _qname, _attributes}, _location, stack),
    do: [{to_string(name), []} | stack]

  defp event({:endElement, _uri, _name, _qname}, _location, [
         {name, children},
         {pname, pchildren} | rest
       ]),
       do: [{pname, [{name, Enum.reverse(children)} | pchildren]} | rest]

  defp event({:characters, text}, _location, [{name, children} | rest]),
    do: [{name, [:unicode.characters_to_binary(text) | children]} | rest]

  defp event(_event, _location, stack), do: stack

  @doc "The child elements of `element` named `name`, in order."
  @spec all(element(), String.t()) :: [element()]
  def all({_name, children}, name), do: for({^name, _} = child <- children, do: child)

  @doc "The text of the first child element named `name`, or `nil`."
  @spec text(element(), String.t()) :: String.t() | nil
  def text(element, name) do
    case all(element, name) do
      [{_name, children} | _] -> children |> Enum.filter(&is_binary/1) |> Enum.join()
      [] -> nil
    end
  end

  @doc "Escape `text` for an XML element's content."
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
