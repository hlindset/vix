defmodule Vix.SourceSpoolTest do
  use ExUnit.Case, async: true

  alias Vix.SourceSpool

  import Vix.Support.Images
  alias Vix.Vips.Image

  # Decode a Vix.Vips.Source via the same internal path new_from_enum uses.
  # operation_call's first output is already a wrapped %Image{} (same as the
  # `wrap_type(ref)` new_from_enum applies — wrap_type is a no-op on a struct).
  defp decode_source(%Vix.Vips.Source{} = source) do
    with {:ok, loader} <- Vix.Vips.Foreign.find_load_source(source),
         {:ok, {%Image{} = image, _}} <-
           Vix.Vips.Operation.Helper.operation_call(loader, [source], []) do
      {:ok, image}
    end
  end

  test "new/1 requires a non-negative integer content_length within max_bytes" do
    assert {:error, :content_length_required} = SourceSpool.new([])
    assert {:error, :invalid_content_length} = SourceSpool.new(content_length: -1)

    assert {:error, :content_length_too_large} =
             SourceSpool.new(content_length: 10, max_bytes: 5)
  end

  test "new/1 creates a spool and finalize/abort are well-behaved" do
    # In this process so that `self()` is the writer (new/1 monitors its caller).
    assert {:ok, spool} = SourceSpool.new(content_length: 0)
    assert :ok = SourceSpool.finalize(spool)
    # idempotent: already DONE
    assert :ok = SourceSpool.finalize(spool)

    assert {:ok, spool2} = SourceSpool.new(content_length: 5)
    assert :ok = SourceSpool.abort(spool2)
    # finalize after abort reports the terminal cause
    assert {:error, :aborted} = SourceSpool.finalize(spool2)
  end

  test "write/2 enforces single-writer, declared length, and terminal state" do
    {:ok, spool} = SourceSpool.new(content_length: 5)

    # not the writer -> :not_owner
    task =
      Task.async(fn -> SourceSpool.write(spool, "x") end)

    assert {:error, :not_owner} = Task.await(task)

    assert :ok = SourceSpool.write(spool, "abc")
    # writing past content_length aborts with :overflow
    assert {:error, :overflow} = SourceSpool.write(spool, "defg")
    # spool is now ABORTED; further writes are rejected
    assert {:error, :aborted} = SourceSpool.write(spool, "h")
  end

  test "write/2 then exact-fill finalize succeeds" do
    {:ok, spool} = SourceSpool.new(content_length: 5)
    assert :ok = SourceSpool.write(spool, "ab")
    assert :ok = SourceSpool.write(spool, "cde")
    assert :ok = SourceSpool.finalize(spool)
    # write after DONE -> :closed
    assert {:error, :closed} = SourceSpool.write(spool, "x")
  end

  test "source/1 over a fully-spooled JPEG decodes to the same shape as the file" do
    bytes = File.read!(img_path("puppies.jpg"))
    {:ok, ref} = Image.new_from_file(img_path("puppies.jpg"))
    expected = {Image.width(ref), Image.height(ref), Image.bands(ref)}

    {:ok, spool} = SourceSpool.new(content_length: byte_size(bytes))
    :ok = SourceSpool.write(spool, bytes)
    :ok = SourceSpool.finalize(spool)
    {:ok, source} = SourceSpool.source(spool)

    {:ok, img} = decode_source(source)
    assert {Image.width(img), Image.height(img), Image.bands(img)} == expected
  end

  # Liveness tests deadlock the VM if the C monitor/condvar wiring is wrong;
  # bound them so a regression fails fast instead of hanging the suite.
  @tag timeout: 10_000
  test "a reader blocks at the frontier and a concurrent writer unblocks it" do
    bytes = File.read!(img_path("puppies.jpg"))
    half = div(byte_size(bytes), 2)
    <<first::binary-size(half), rest::binary>> = bytes

    {:ok, spool} = SourceSpool.new(content_length: byte_size(bytes))
    {:ok, source} = SourceSpool.source(spool)

    # Decode in a separate process; it will block reading past `first`.
    parent = self()
    decoder = spawn_link(fn ->
      {:ok, img} = decode_source(source)
      send(parent, {:decoded, Image.width(img), Image.height(img)})
    end)

    :ok = SourceSpool.write(spool, first)
    refute_received {:decoded, _, _}          # still blocked at the frontier
    :ok = SourceSpool.write(spool, rest)
    :ok = SourceSpool.finalize(spool)

    assert_receive {:decoded, w, h}, 5_000
    assert w > 0 and h > 0
    _ = decoder
  end

  @tag timeout: 10_000
  test "killing the writer wakes a parked reader with an error" do
    bytes = File.read!(img_path("puppies.jpg"))

    parent = self()
    # The writer process owns the spool; it sends the source out, then parks.
    writer = spawn(fn ->
      {:ok, spool} = SourceSpool.new(content_length: byte_size(bytes))
      {:ok, source} = SourceSpool.source(spool)
      send(parent, {:source, source})
      Process.sleep(:infinity)   # never writes; dies on kill below
    end)

    source = receive do {:source, s} -> s after 1_000 -> flunk("no source") end

    decoder = spawn_link(fn ->
      result = decode_source(source)
      send(parent, {:decode_result, result})
    end)

    Process.sleep(50)            # let the decoder park at the frontier
    Process.exit(writer, :kill)  # monitor-down -> ABORTED -> reader wakes

    assert_receive {:decode_result, {:error, _}}, 5_000
    _ = decoder
  end
end
