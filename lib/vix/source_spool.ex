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

  @spec source(t) :: {:ok, Vix.Vips.Source.t()} | {:error, :aborted | term}
  def source(%SourceSpool{ref: ref}) do
    with {:ok, src_ref} <- Nif.nif_source_spool_source(ref) do
      {:ok, %Source{ref: src_ref}}
    end
  end

  @spec start_feeder(Enumerable.t(), keyword) :: {:ok, t, pid} | {:error, term}
  def start_feeder(enum, opts) do
    case Keyword.fetch(opts, :content_length) do
      :error -> {:error, :content_length_required}   # don't raise; match the rest of the API
      {:ok, len} -> do_start_feeder(enum, opts, len)
    end
  end

  defp do_start_feeder(enum, opts, len) do
    parent = self()

    {writer, mon} =
      spawn_monitor(fn ->
        case new(opts) do
          {:ok, spool} ->
            send(parent, {self(), {:ok, spool}})
            feed_spool(enum, spool, len)

          {:error, _} = err ->
            send(parent, {self(), err})
        end
      end)

    receive do
      {^writer, {:ok, spool}} ->
        Process.demonitor(mon, [:flush])
        {:ok, spool, writer}

      {^writer, {:error, _} = err} ->
        Process.demonitor(mon, [:flush])
        err

      {:DOWN, ^mon, :process, ^writer, reason} ->
        {:error, reason}
    end
  end

  # Zero-length: finalize WITHOUT pulling the enum (a blocking empty stream
  # would otherwise deadlock readers at EOF).
  defp feed_spool(_enum, spool, 0), do: finalize(spool)

  defp feed_spool(enum, spool, len) when len > 0 do
    try do
      enum
      |> Enum.reduce_while(0, fn iodata, written ->
        case IO.iodata_to_binary(iodata) do
          "" ->
            {:cont, written}   # skip empty chunks (no-op write; avoids pathological spins)

          bin ->
            case write(spool, bin) do
              :ok ->
                case written + byte_size(bin) do
                  ^len -> finalize(spool); {:halt, :filled}
                  n -> {:cont, n}
                end

              {:error, _} ->
                {:halt, :stopped}
            end
        end
      end)
      |> case do
        :filled -> :ok
        :stopped -> :ok
        n when is_integer(n) -> finalize(spool)  # enum ended early -> {:error, :short}
      end
    rescue
      _ -> abort(spool)
    catch
      _, _ -> abort(spool)
    end
  end

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
