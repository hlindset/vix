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

  describe "start_feeder/2" do
    test "feeds an enum and decodes" do
      bytes = File.read!(img_path("puppies.jpg"))
      chunks = for <<c::binary-size(8192) <- bytes>>, do: c
      tail = binary_part(bytes, length(chunks) * 8192, byte_size(bytes) - length(chunks) * 8192)
      enum = chunks ++ [tail]

      {:ok, spool, _writer} =
        SourceSpool.start_feeder(enum, content_length: byte_size(bytes))

      {:ok, source} = SourceSpool.source(spool)
      {:ok, img} = decode_source(source)
      assert Image.width(img) > 0
    end

    @tag timeout: 10_000
    test "finalizes at exactly content_length without pulling an extra (blocking) item" do
      bytes = File.read!(img_path("puppies.jpg"))
      # An enum that yields the whole body, then BLOCKS forever if pulled again.
      enum = Stream.resource(
        fn -> :first end,
        fn
          :first -> {[bytes], :done}
          :done -> Process.sleep(:infinity)  # must never be reached
        end,
        fn _ -> :ok end
      )

      {:ok, spool, _writer} =
        SourceSpool.start_feeder(enum, content_length: byte_size(bytes))

      {:ok, source} = SourceSpool.source(spool)
      assert {:ok, _img} = decode_source(source)
    end

    test "content_length: 0 finalizes without touching the enum" do
      enum = Stream.map([:boom], fn _ -> raise "must not be pulled" end)
      assert {:ok, _spool, _writer} =
               SourceSpool.start_feeder(enum, content_length: 0)
    end
  end

  test "two independent sources over one spool decode the same bytes" do
    bytes = File.read!(img_path("boats.tif"))
    {:ok, spool} = SourceSpool.new(content_length: byte_size(bytes))
    :ok = SourceSpool.write(spool, bytes)
    :ok = SourceSpool.finalize(spool)

    {:ok, s1} = SourceSpool.source(spool)
    {:ok, s2} = SourceSpool.source(spool)

    {:ok, i1} = decode_source(s1)
    {:ok, i2} = decode_source(s2)
    assert Image.width(i1) == Image.width(i2)
    assert Image.height(i1) == Image.height(i2)
  end

  test "all spool NIFs are registered (not stub-raising)" do
    # If a vix.c table entry is mis-bound, the NIF stays the .ex stub and raises
    # :nif_library_not_loaded. A successful new/finalize exercises new+finalize;
    # write/source/abort are covered by the tests above. This asserts the load.
    assert {:ok, spool} = SourceSpool.new(content_length: 1)
    assert :ok = SourceSpool.write(spool, "x")
    assert {:ok, _source} = SourceSpool.source(spool)
    assert :ok = SourceSpool.finalize(spool)
    assert :ok = SourceSpool.abort(spool)
  end

  # Helper: an enum that yields nothing and blocks forever if pulled.
  defp blocking_enum,
    do: Stream.resource(fn -> :s end, fn :s -> Process.sleep(:infinity) end, fn _ -> :ok end)

  # (1) The design's "single most important contract": start_feeder makes the FEEDER the
  # monitored writer. Killing the feeder (not the test process) must wake a parked reader.
  @tag timeout: 10_000
  test "start_feeder monitors the feeder: killing it wakes a parked reader" do
    {:ok, spool, writer} =
      SourceSpool.start_feeder(blocking_enum(), content_length: 1000)

    {:ok, source} = SourceSpool.source(spool)
    parent = self()
    _decoder = spawn_link(fn -> send(parent, {:res, decode_source(source)}) end)

    Process.sleep(50)            # decoder parks at the frontier (nothing written yet)
    Process.exit(writer, :kill)  # feeder is the monitored writer
    assert_receive {:res, {:error, _}}, 5_000
  end

  # (2) The spawn_monitor payoff: a feeder :kill surfaces as an API error, never crashes the
  # caller — even when the caller traps exits.
  @tag timeout: 10_000
  test "a feeder :kill does not crash the caller; the spool reports :aborted" do
    Process.flag(:trap_exit, true)
    {:ok, spool, writer} = SourceSpool.start_feeder(blocking_enum(), content_length: 1000)
    Process.exit(writer, :kill)
    Process.sleep(50)
    assert {:error, :aborted} = SourceSpool.source(spool)  # caller still alive & usable
  after
    Process.flag(:trap_exit, false)
  end

  # (3) Short stream: finalize before content_length aborts with :short.
  test "finalize before content_length returns :short" do
    {:ok, spool} = SourceSpool.new(content_length: 10)
    :ok = SourceSpool.write(spool, "abc")
    assert {:error, :short} = SourceSpool.finalize(spool)
  end

  # (5) Abort responsiveness: abort concurrent with a large multi-slice write must not deadlock.
  # (The "stops within ~one SPOOL_MAX_SLICE" property is structural — verify by reading the
  # lock-per-slice loop; this test guards against a deadlock regression.)
  @tag timeout: 10_000
  test "abort/1 concurrent with a large write does not deadlock" do
    big = :binary.copy("x", 8 * 1024 * 1024)
    {:ok, spool} = SourceSpool.new(content_length: byte_size(big))
    spawn(fn -> SourceSpool.abort(spool) end)
    assert SourceSpool.write(spool, big) in [:ok, {:error, :aborted}]
  end

  # (6) SEEK_END length-cache pin. A TIFF loader probes source length early (SEEK_END). Feeding a
  # TIFF in two halves and decoding correctly proves SEEK_END returns content_length, NOT the
  # write frontier — the exact bug the content_length requirement defends against. (A truly direct
  # seek-callback unit test isn't possible from Elixir; this end-to-end shape is the real pin.)
  @tag timeout: 10_000
  test "TIFF fed incrementally decodes — SEEK_END returns content_length, not the frontier" do
    bytes = File.read!(img_path("boats.tif"))
    half = div(byte_size(bytes), 2)
    <<first::binary-size(half), rest::binary>> = bytes

    {:ok, spool} = SourceSpool.new(content_length: byte_size(bytes))
    {:ok, source} = SourceSpool.source(spool)
    parent = self()
    _decoder = spawn_link(fn -> send(parent, {:res, decode_source(source)}) end)

    :ok = SourceSpool.write(spool, first)
    :ok = SourceSpool.write(spool, rest)
    :ok = SourceSpool.finalize(spool)
    assert_receive {:res, {:ok, _img}}, 5_000
  end

  # (7) source/1 after abort returns :aborted, synchronously (direct unit).
  test "source/1 after abort returns :aborted" do
    {:ok, spool} = SourceSpool.new(content_length: 10)
    :ok = SourceSpool.abort(spool)
    assert {:error, :aborted} = SourceSpool.source(spool)
  end

  # (8) Zero-length source: bounded EOF, decode errors rather than hanging.
  @tag timeout: 10_000
  test "zero-length source decodes to an error without hanging" do
    {:ok, spool} = SourceSpool.new(content_length: 0)
    :ok = SourceSpool.finalize(spool)
    {:ok, source} = SourceSpool.source(spool)
    assert {:error, _} = decode_source(source)
  end

  test "image retains its source: buffer survives GC of BOTH the spool handle and the source term" do
    bytes = File.read!(img_path("puppies.jpg"))

    # Create the spool handle AND the source inside the closure, so after it returns the ONLY
    # path keeping the buffer alive is the image retaining the source. If the load op did not
    # retain it, the buffer would be freed and the eval below would use-after-free.
    img =
      (fn ->
         {:ok, spool} = SourceSpool.new(content_length: byte_size(bytes))
         :ok = SourceSpool.write(spool, bytes)
         :ok = SourceSpool.finalize(spool)
         {:ok, source} = SourceSpool.source(spool)
         {:ok, img} = decode_source(source)
         img
       end).()

    :erlang.garbage_collect()
    # Definitive UAF detection is the valgrind/ASan run in Step 3 (GC + Janitor unref is async,
    # so a clean pass here is necessary-but-not-sufficient).
    assert {:ok, _bin} = Image.write_to_buffer(img, ".png")
  end

  # ---- concurrent (parallel) decode from one spool ----

  # Several sources over one FINALIZED spool, decoded simultaneously (independent cursors,
  # shared buffer under one lock). Uses a seek-heavy TIFF to exercise concurrent seeks.
  @tag timeout: 15_000
  test "multiple sources decode one spool concurrently" do
    {:ok, ref} = Image.new_from_file(img_path("boats.tif"))
    expected = {Image.width(ref), Image.height(ref)}
    bytes = File.read!(img_path("boats.tif"))

    {:ok, spool} = SourceSpool.new(content_length: byte_size(bytes))
    :ok = SourceSpool.write(spool, bytes)
    :ok = SourceSpool.finalize(spool)

    tasks =
      for _ <- 1..4 do
        {:ok, source} = SourceSpool.source(spool)

        Task.async(fn ->
          {:ok, img} = decode_source(source)
          {Image.width(img), Image.height(img)}
        end)
      end

    assert Enum.all?(Task.await_many(tasks, 12_000), &(&1 == expected))
  end

  # Overlap: parallel decoders park at the frontier on a spool that is NOT yet filled, then the
  # writer feeds in chunks. The condvar broadcast must wake all parked readers and each must
  # complete with the correct image.
  @tag timeout: 15_000
  test "parallel decoders over a still-filling spool all complete (overlap)" do
    {:ok, ref} = Image.new_from_file(img_path("boats.tif"))
    expected = {Image.width(ref), Image.height(ref)}
    bytes = File.read!(img_path("boats.tif"))
    total = byte_size(bytes)

    {:ok, spool} = SourceSpool.new(content_length: total)

    # Mint sources and start decoders BEFORE any bytes are written — they park at the frontier.
    tasks =
      for _ <- 1..3 do
        {:ok, source} = SourceSpool.source(spool)

        Task.async(fn ->
          {:ok, img} = decode_source(source)
          {Image.width(img), Image.height(img)}
        end)
      end

    Process.sleep(50)

    chunk = 16_384

    for offset <- 0..(total - 1)//chunk do
      :ok = SourceSpool.write(spool, binary_part(bytes, offset, min(chunk, total - offset)))
    end

    :ok = SourceSpool.finalize(spool)

    assert Enum.all?(Task.await_many(tasks, 12_000), &(&1 == expected))
  end

  # ---- status/1 ----

  test "status/1 reports the terminal state and abort cause" do
    {:ok, open} = SourceSpool.new(content_length: 10)
    assert :open == SourceSpool.status(open)
    :ok = SourceSpool.write(open, "abc")
    assert :open == SourceSpool.status(open)

    {:ok, done} = SourceSpool.new(content_length: 5)
    :ok = SourceSpool.write(done, "abcde")
    :ok = SourceSpool.finalize(done)
    assert :done == SourceSpool.status(done)

    {:ok, overflow} = SourceSpool.new(content_length: 5)
    :ok = SourceSpool.write(overflow, "abc")
    assert {:error, :overflow} = SourceSpool.write(overflow, "defgh")
    assert {:aborted, :overflow} == SourceSpool.status(overflow)

    {:ok, short} = SourceSpool.new(content_length: 10)
    :ok = SourceSpool.write(short, "abc")
    assert {:error, :short} = SourceSpool.finalize(short)
    assert {:aborted, :short} == SourceSpool.status(short)

    {:ok, cancelled} = SourceSpool.new(content_length: 10)
    :ok = SourceSpool.abort(cancelled)
    assert {:aborted, :cancelled} == SourceSpool.status(cancelled)
  end

  @tag timeout: 10_000
  test "status/1 reports {:aborted, :writer_down} when the writer dies" do
    parent = self()

    writer =
      spawn(fn ->
        {:ok, spool} = SourceSpool.new(content_length: 10)
        send(parent, {:spool, spool})
        Process.sleep(:infinity)
      end)

    spool = receive do: ({:spool, s} -> s), after: (1_000 -> flunk("no spool"))
    Process.exit(writer, :kill)
    Process.sleep(50)
    assert {:aborted, :writer_down} == SourceSpool.status(spool)
  end
end
