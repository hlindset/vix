defmodule Vix.SourceSpool do
  @moduledoc """
  A seekable, concurrent libvips source backed by a pre-allocated in-memory
  buffer fed from Elixir while libvips decodes.

  Prefer `start_feeder/2`: it starts a feeder process that owns writes/finalization
  and returns a spool handle for `source/1` and `abort/1`. The feeder stays the
  writer — the caller must not `write/2`/`finalize/1`. `new/1`, `write/2`, and
  `finalize/1` are low-level: the process that calls `new/1` becomes the only
  process allowed to `write/2`/`finalize/1`, and its death aborts the spool.
  `abort/1` is callable from any process holding the handle.
  """

  alias Vix.Nif
  alias Vix.Vips.Source
  alias __MODULE__

  @opaque t :: %__MODULE__{ref: term()}
  defstruct [:ref]

  @default_max_bytes 104_857_600

  @spec new(keyword) :: {:ok, t} | {:error, term}
  def new(opts) do
    len = Keyword.get(opts, :content_length)
    max = Keyword.get(opts, :max_bytes, default_max_bytes())

    with :ok <- validate_content_length(len, max),
         {:ok, ref} <- Nif.nif_source_spool_new(len) do
      {:ok, %SourceSpool{ref: ref}}
    end
  end

  @spec write(t, binary) :: :ok | {:error, :closed | :aborted | :overflow | :not_owner}
  def write(%SourceSpool{ref: ref}, bin) when is_binary(bin),
    do: Nif.nif_source_spool_write(ref, bin)

  @spec finalize(t) :: :ok | {:error, term}
  def finalize(%SourceSpool{ref: ref}), do: Nif.nif_source_spool_finalize(ref)

  @spec abort(t) :: :ok
  def abort(%SourceSpool{ref: ref}), do: Nif.nif_source_spool_abort(ref)

  @doc false
  def default_max_bytes,
    do: Application.get_env(:vix, :source_spool_max_bytes, @default_max_bytes)

  defp validate_content_length(len, _max) when not is_integer(len),
    do: {:error, :content_length_required}

  defp validate_content_length(len, _max) when len < 0,
    do: {:error, :invalid_content_length}

  defp validate_content_length(len, max) when len > max,
    do: {:error, :content_length_too_large}

  defp validate_content_length(_len, _max), do: :ok
end
