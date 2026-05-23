defmodule EzagentDomainPython.FrameBuffer do
  @moduledoc """
  Incremental LSP-frame parser — converts arbitrary stdout byte chunks
  into a stream of complete `Content-Length: N\\r\\n\\r\\n<body>` frame
  bodies.

  Per SPEC `docs/superpowers/specs/2026-05-23-domain-python.md` §2.1
  Domain.Python keeps the LSP framing used by `JsonRpc.encode_frame/1`
  so binary-clean payloads (embedded `\\n` in chat replies, base64
  image data, etc.) cross the wire intact. erlexec delivers stdout in
  arbitrary-size chunks; this buffer holds the partial state between
  chunks and emits whole bodies in order.

  ## Usage

      buf = FrameBuffer.new()
      {buf, frames} = FrameBuffer.feed(buf, chunk1)
      {buf, frames} = FrameBuffer.feed(buf, chunk2)

  Each emitted frame is the raw JSON body (a binary), ready to hand to
  `EzagentDomainPython.JsonRpc.decode_body/1`.

  Headers other than `Content-Length` are accepted + ignored
  (`Content-Type: application/vscode-jsonrpc; charset=utf-8` per LSP)
  matching what the encoder may emit in future revisions. The parser
  rejects malformed headers (missing `Content-Length`, non-numeric
  length, header line with no colon) by raising — a malformed frame
  means the subprocess sent garbage which is a hard error; the caller
  Server tears the subprocess down.
  """

  defstruct buffer: <<>>

  @type t :: %__MODULE__{buffer: binary()}

  @doc "Empty starting state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed `chunk` into `state`. Returns `{new_state, frames}` where
  `frames` is a (possibly empty) list of complete frame bodies in
  arrival order.

  Raises `ArgumentError` if a header block is malformed (missing
  Content-Length, non-numeric value, garbled line). This is the
  let-it-crash path: malformed bytes from the subprocess are a
  protocol violation, not a recoverable condition.
  """
  @spec feed(t(), binary()) :: {t(), [binary()]}
  def feed(%__MODULE__{buffer: buf}, chunk) when is_binary(chunk) do
    drain(%__MODULE__{buffer: buf <> chunk}, [])
  end

  # Drain as many complete frames as the buffer holds.
  defp drain(%__MODULE__{buffer: buf} = state, acc) do
    case :binary.split(buf, "\r\n\r\n") do
      [_only] ->
        # No complete header block yet — wait for more bytes.
        {state, Enum.reverse(acc)}

      [header_block, rest] ->
        content_length = parse_content_length!(header_block)

        if byte_size(rest) >= content_length do
          <<body::binary-size(content_length), tail::binary>> = rest
          drain(%__MODULE__{buffer: tail}, [body | acc])
        else
          # Header complete but body still arriving; keep header in
          # the buffer until the body's bytes show up.
          {state, Enum.reverse(acc)}
        end
    end
  end

  # Walk the header block and pull out the Content-Length value.
  # Other headers are accepted + ignored. Missing / malformed
  # Content-Length raises.
  defp parse_content_length!(header_block) do
    header_block
    |> :binary.split("\r\n", [:global])
    |> Enum.reduce(nil, fn line, acc ->
      case parse_header_line(line) do
        {"content-length", value} ->
          case Integer.parse(value) do
            {n, ""} when n >= 0 -> n
            _ -> raise ArgumentError, "FrameBuffer: malformed Content-Length: #{inspect(value)}"
          end

        {_other, _value} ->
          acc

        :empty ->
          acc
      end
    end)
    |> case do
      nil -> raise ArgumentError, "FrameBuffer: missing Content-Length header in #{inspect(header_block)}"
      n -> n
    end
  end

  defp parse_header_line(""), do: :empty

  defp parse_header_line(line) when is_binary(line) do
    case :binary.split(line, ":") do
      [name, value] ->
        {name |> String.trim() |> String.downcase(), String.trim(value)}

      _ ->
        raise ArgumentError, "FrameBuffer: malformed header line: #{inspect(line)}"
    end
  end
end
