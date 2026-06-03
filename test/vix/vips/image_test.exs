defmodule Vix.Vips.ImageTest do
  use ExUnit.Case, async: true

  alias Vix.Vips.Image
  alias Vix.Vips.MutableImage

  import Vix.Support.Images

  doctest Image

  test "new_from_file" do
    assert {:error, :invalid_path} == Image.new_from_file("invalid.jpg", [])
    assert {:error, "Failed to find load"} == Image.new_from_file(__ENV__.file, [])

    assert {:ok, %Image{ref: ref}} = Image.new_from_file(img_path("puppies.jpg"))
    assert is_reference(ref)
  end

  test "new_from_file supports optional arguments" do
    assert {:ok, %Image{ref: ref} = img1} = Image.new_from_file(img_path("puppies.jpg"))
    assert is_reference(ref)

    assert {:ok, %Image{ref: ref} = img2} =
             Image.new_from_file(img_path("puppies.jpg"), shrink: 2)

    assert is_reference(ref)

    assert Image.width(img1) == 2 * Image.width(img2)
  end

  test "new_from_file supports optional options suffix" do
    assert {:ok, %Image{ref: ref} = img1} =
             Image.new_from_file(img_path("puppies.jpg"))

    assert is_reference(ref)

    assert {:ok, %Image{ref: ref} = img2} =
             Image.new_from_file(img_path("puppies.jpg") <> "[shrink=2]")

    assert is_reference(ref)

    assert Image.width(img1) == 2 * Image.width(img2)
  end

  test "new_from_file ignores invalid options" do
    # png does not support `shrink` option
    assert {:ok, %Image{ref: ref}} =
             Image.new_from_file(img_path("gradient.png"), shrink: 2)

    assert is_reference(ref)
  end

  test "new_from_buffer" do
    assert {:error, "Failed to find load buffer"} == Image.new_from_buffer(<<>>)

    path = img_path("puppies.jpg")

    assert {:ok, img_from_buf} = Image.new_from_buffer(File.read!(path))
    img_buf_out_path = Briefly.create!(extname: ".png")
    assert :ok == Image.write_to_file(img_from_buf, img_buf_out_path)

    {:ok, img_from_file} = Image.new_from_file(path)
    img_file_out_path = Briefly.create!(extname: ".png")
    assert :ok == Image.write_to_file(img_from_file, img_file_out_path)

    assert File.read!(img_buf_out_path) == File.read!(img_file_out_path)
  end

  describe "write_to_file" do
    test "write_to_file" do
      path = img_path("puppies.jpg")

      {:ok, %Image{ref: ref} = im} = Image.new_from_file(path)
      assert is_reference(ref)

      out_path = Briefly.create!(extname: ".png")
      assert :ok == Image.write_to_file(im, out_path)

      stat = File.stat!(out_path)
      assert stat.size > 0 and stat.type == :regular
    end

    test "write_to_file supports optional arguments" do
      {:ok, img} = Image.new_from_file(img_path("puppies.jpg"))

      out_path1 = Briefly.create!(extname: ".png")
      assert :ok = Image.write_to_file(img, out_path1, compression: 0)

      out_path2 = Briefly.create!(extname: ".png")
      assert :ok = Image.write_to_file(img, out_path2, compression: 9)

      # currently I only found this option to be verifiable easily!
      assert File.stat!(out_path1).size > File.stat!(out_path2).size
    end

    test "write_to_file supports optional options suffix" do
      {:ok, img} = Image.new_from_file(img_path("puppies.jpg"))

      out_path1 = Briefly.create!(extname: ".png")
      assert :ok = Image.write_to_file(img, out_path1 <> "[compression=0]")

      out_path2 = Briefly.create!(extname: ".png")
      assert :ok = Image.write_to_file(img, out_path2 <> "[compression=9]")

      # currently I only found this option to be verifiable easily!
      assert File.stat!(out_path1).size > File.stat!(out_path2).size
    end
  end

  test "new_matrix_from_array" do
    assert {:ok, img} =
             Image.new_matrix_from_array(2, 2, [
               [-1, -1],
               [0, 16]
             ])

    assert %{width: 2, height: 2} = Image.headers(img)

    assert {:ok,
            <<
              (<<-1::little-float, -1::little-float>>),
              (<<0::little-float, 16::little-float>>)
            >>} = Image.write_to_binary(img)
  end

  describe "new_from_list" do
    test "when argument is range" do
      assert {:ok, img} = Image.new_from_list(0..2)

      assert %{width: 3, height: 1} = Image.headers(img)

      assert {:ok, <<0::little-float, 1::little-float, 2::little-float>>} =
               Image.write_to_binary(img)
    end

    test "when argument is range within list" do
      assert {:ok, img} = Image.new_from_list([0..1, -1..0])

      assert %{width: 2, height: 2} = Image.headers(img)

      assert {:ok,
              <<
                (<<0::little-float, 1::little-float>>),
                (<<-1::little-float, 0::little-float>>)
              >>} = Image.write_to_binary(img)
    end

    test "when list is 1D" do
      assert {:ok, img} = Image.new_from_list([0, 1, 2])

      assert %{width: 3, height: 1} = Image.headers(img)

      assert {:ok, <<0::little-float, 1::little-float, 2::little-float>>} =
               Image.write_to_binary(img)
    end

    test "when list is 2D" do
      assert {:ok, img} =
               Image.new_from_list([
                 [1, 2, 3],
                 [-1, -2, -3]
               ])

      assert %{width: 3, height: 2} = Image.headers(img)

      assert {:ok,
              <<
                (<<1::little-float, 2::little-float, 3::little-float>>),
                (<<-1::little-float, -2::little-float, -3::little-float>>)
              >>} = Image.write_to_binary(img)
    end
  end

  test "mutate" do
    {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))

    {:ok, updated_image} =
      Image.mutate(im, fn mut_image ->
        :ok = MutableImage.update(mut_image, "orientation", 0)
        :ok = MutableImage.set(mut_image, "new-field", :gint, 0)
      end)

    assert {:ok, 0} = Image.header_value(updated_image, "orientation")
    assert {:ok, 0} = Image.header_value(updated_image, "new-field")
  end

  test "get_fields" do
    {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))
    assert {:ok, fields} = Image.header_field_names(im)

    assert Enum.all?(
             [
               "vips-loader",
               "filename",
               "yres",
               "xres",
               "yoffset",
               "xoffset",
               "bands",
               "height",
               "width"
             ],
             &Enum.member?(fields, &1)
           )
  end

  test "get_header" do
    {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))
    assert {:ok, 518} = Image.header_value(im, "width")
  end

  test "headers" do
    {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))

    assert %{
             bands: 3,
             coding: :VIPS_CODING_NONE,
             filename: _filename,
             format: :VIPS_FORMAT_UCHAR,
             height: 389,
             interpretation: :VIPS_INTERPRETATION_sRGB,
             mode: nil,
             "n-pages": nil,
             offset: nil,
             orientation: 1,
             "page-height": nil,
             scale: nil,
             width: 518,
             xoffset: 0,
             xres: 2.834645669291339,
             yoffset: 0,
             yres: 2.834645669291339
           } = Image.headers(im)
  end

  test "get_header binary" do
    {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))
    assert {:ok, <<_::binary>>} = Image.header_value(im, "exif-data")
  end

  test "get_as_string" do
    {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))

    assert {:ok, "((VipsInterpretation) VIPS_INTERPRETATION_sRGB)"} =
             Image.header_value_as_string(im, "interpretation")
  end

  test "macro generated function" do
    {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))
    assert 518 == Image.width(im)
    assert :VIPS_INTERPRETATION_sRGB == Image.interpretation(im)

    {:ok, im} = Image.new_from_file(img_path("boats.tif"))
    assert 2 == Image.n_pages(im)
  end

  describe "write_to_buffer" do
    test "write image to buffer" do
      {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))
      {:ok, _bin} = Image.write_to_buffer(im, ".jpg[Q=90]")
    end

    test "write_to_buffer supports optional arguments" do
      {:ok, img} = Image.new_from_file(img_path("puppies.jpg"))

      assert {:ok, bin1} = Image.write_to_buffer(img, ".png", compression: 0)
      assert {:ok, bin2} = Image.write_to_buffer(img, ".png", compression: 9)

      # currently I only found this option to be verifiable easily!
      assert byte_size(bin1) > byte_size(bin2)
    end

    test "write_to_buffer supports optional options suffix" do
      {:ok, img} = Image.new_from_file(img_path("puppies.jpg"))

      assert {:ok, bin1} = Image.write_to_buffer(img, ".png[compression=0]")
      assert {:ok, bin2} = Image.write_to_buffer(img, ".png[compression=9]")

      # currently I only found this option to be verifiable easily!
      assert byte_size(bin1) > byte_size(bin2)
    end
  end

  test "new image from other image" do
    {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))
    {:ok, new_im} = Image.new_from_image(im, [250])

    assert Image.width(im) == Image.width(new_im)
    assert Image.height(im) == Image.height(new_im)
    assert Image.bands(new_im) == 1
  end

  test "image has an alpha band" do
    {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))
    refute Image.has_alpha?(im)

    {:ok, im} = Image.new_from_file(img_path("alpha_band.png"))
    assert Image.has_alpha?(im)
  end

  describe "new_from_enum" do
    test "new_from_enum" do
      {:ok, image} =
        File.stream!(img_path("puppies.jpg"), 1024, [])
        |> Image.new_from_enum("")

      out_path = Briefly.create!(extname: ".png")
      :ok = Image.write_to_file(image, out_path)

      stat = File.stat!(out_path)
      assert stat.size > 0 and stat.type == :regular
    end

    @tag capture_log: true
    test "new_from_enum invalid data write" do
      {:error, "Failed to find loader for the source"} = Image.new_from_enum(1..100)
    end

    test "premature end of new_from_enum" do
      {:error, "Failed to create image from VipsSource"} =
        File.stream!(img_path("puppies.jpg"), 100, [])
        |> Stream.take(1)
        |> Image.new_from_enum("")
    end

    test "passing options as keyword" do
      {:ok, img1} = Image.new_from_file(img_path("puppies.jpg"))

      {:ok, img2} =
        File.stream!(img_path("puppies.jpg"), 100, [])
        |> Image.new_from_enum(shrink: 2)

      assert Image.width(img1) == 2 * Image.width(img2)
    end

    test "passing options as string" do
      {:ok, img1} = Image.new_from_file(img_path("puppies.jpg"))

      {:ok, img2} =
        File.stream!(img_path("puppies.jpg"), 1024, [])
        |> Image.new_from_enum("[shrink=2]")

      assert Image.width(img1) == 2 * Image.width(img2)
    end
  end

  describe "write_to_stream" do
    test "write_to_stream" do
      {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))

      out_path = Briefly.create!(extname: ".png")

      :ok =
        Image.write_to_stream(im, ".png")
        |> Stream.into(File.stream!(out_path))
        |> Stream.run()

      stat = File.stat!(out_path)
      assert stat.size > 0 and stat.type == :regular
    end

    test "write_to_stream with invalid suffix" do
      {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))

      out_path = Briefly.create!(extname: ".png")

      assert_raise Vix.Vips.Image.Error, fn ->
        Image.write_to_stream(im, ".invalid")
        |> Stream.into(File.stream!(out_path))
        |> Stream.run()
      end
    end

    test "passing options as keyword" do
      {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))

      buf1 =
        Image.write_to_stream(im, ".png", compression: 0)
        |> Enum.into([])

      {:ok, buf2} = Image.write_to_buffer(im, ".png", compression: 9)

      assert IO.iodata_length(buf1) > byte_size(buf2)
    end

    test "passing options as string" do
      {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))

      buf1 =
        Image.write_to_stream(im, ".png[compression=0]")
        |> Enum.into([])

      {:ok, buf2} = Image.write_to_buffer(im, ".png", compression: 9)

      assert IO.iodata_length(buf1) > byte_size(buf2)
    end
  end

  test "new_from_binary" do
    {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))
    # same image in raw pixel format
    bin = File.read!(img_path("puppies.raw"))

    assert {:ok, image} =
             Image.new_from_binary(
               bin,
               Image.width(im),
               Image.height(im),
               Image.bands(im),
               Image.format(im)
             )

    out_path = Briefly.create!(extname: ".png")
    :ok = Image.write_to_file(image, out_path)

    stat = File.stat!(out_path)
    assert stat.size > 0 and stat.type == :regular
  end

  test "write_to_binary" do
    {:ok, im} = Image.new_from_file(img_path("black.jpg"))
    assert {:ok, bin} = Image.write_to_binary(im)

    expected_bin_size = Image.width(im) * Image.height(im) * Image.bands(im)

    assert IO.iodata_length(bin) == expected_bin_size
    assert :binary.copy(<<0>>, expected_bin_size) == bin
  end

  test "write_to_tensor" do
    {:ok, im} = Image.new_from_file(img_path("black.jpg"))
    assert {:ok, %Vix.Tensor{} = tensor} = Image.write_to_tensor(im)

    assert tensor.shape == {Image.height(im), Image.width(im), Image.bands(im)}

    expected_bin_size = Image.width(im) * Image.height(im) * Image.bands(im)
    assert tensor.data == :binary.copy(<<0>>, expected_bin_size)
  end

  test "to_list" do
    {:ok, im} = Image.new_from_file(img_path("black.jpg"))

    {:ok, list} = Image.to_list(im)

    assert length(list) == Image.height(im)
    assert length(hd(list)) == Image.width(im)
    assert length(hd(hd(list))) == Image.bands(im)
  end

  test "supported_saver_suffixes" do
    {:ok, list} = Image.supported_saver_suffixes()

    for suffix <- ~w(.jpeg .png .gif .tiff .vips .raw) do
      assert suffix in list
    end
  end

  test "supported_loader_suffixes" do
    {:ok, list} = Image.supported_loader_suffixes()

    for suffix <- ~w(.jpeg .png .gif .tiff .vips .svg) do
      assert suffix in list
    end
  end

  test "new_from_binary and write_to_binary endianness handling" do
    {width, height} = {125, 125}

    # generate a test pixel data in native endianness
    bin =
      for y <- 1..height, into: <<>> do
        for x <- 1..width, into: <<>> do
          <<y * 2.0::native-float-32, 0::native-float-32, x * 2.0::native-float-32>>
        end
      end

    {:ok, img} = Image.new_from_binary(bin, width, height, 3, :VIPS_FORMAT_FLOAT)

    # endianness file read from disk and from memory must be same
    {:ok, expected} = Image.new_from_file(img_path("gradient.png"))
    assert_images_equal(expected, img)

    out_path = Briefly.create!(extname: ".v")
    :ok = Image.write_to_file(img, out_path)

    {:ok, vimg} = Image.new_from_file(out_path)
    {:ok, vbin} = Image.write_to_binary(vimg)

    # endianness file written to disk and memory must be same
    assert bin == vbin
  end

  test "get_pixel" do
    {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))
    assert {:ok, [r, g, b]} = Image.get_pixel(im, 10, 10)
    assert [r, g, b] == [80, 101, 62]

    {:ok, im} = Image.new_from_file(img_path("black.jpg"))
    assert {:ok, [0]} = Image.get_pixel(im, 10, 10)

    {:ok, im} = Image.new_from_file(img_path("alpha_band.png"))
    assert {:ok, [r, g, b, a]} = Image.get_pixel(im, 50, 10)
    assert [r, g, b, a] == [247, 247, 247, 255]
  end

  test "get_pixel!" do
    {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))
    assert [x, y, z] = Image.get_pixel!(im, 10, 10)
    assert [x, y, z] == [80, 101, 62]

    assert_raise Image.Error, "Bad extract area. Ensure params are not out of bound", fn ->
      Image.get_pixel!(im, 10, 1000)
    end
  end

  test "copy_memory" do
    {:ok, im} = Image.new_from_file(img_path("puppies.jpg"))

    # Test successful copy
    assert {:ok, memory_im} = Image.copy_memory(im)
    assert %Image{} = memory_im

    # Verify the copied image has the same properties
    assert Image.width(memory_im) == Image.width(im)
    assert Image.height(memory_im) == Image.height(im)
    assert Image.bands(memory_im) == Image.bands(im)

    # Verify pixel data is identical
    assert Image.get_pixel!(memory_im, 10, 10) == Image.get_pixel!(im, 10, 10)

    # Test that copy_memory can be called multiple times
    assert {:ok, _memory_im2} = Image.copy_memory(memory_im)
  end

  describe "new_from_enum mode" do
    defp chunked(path, size \\ 8192) do
      bytes = File.read!(path)
      chunks = for <<c::binary-size(size) <- bytes>>, do: c
      used = length(chunks) * size
      tail = binary_part(bytes, used, byte_size(bytes) - used)
      enum = if tail == "", do: chunks, else: chunks ++ [tail]
      {enum, byte_size(bytes)}
    end

    for name <- ["puppies.jpg", "gradient.png", "boats.tif"] do
      test "decodes #{name} identically to new_from_file" do
        path = img_path(unquote(name))
        {:ok, ref} = Image.new_from_file(path)
        {enum, len} = chunked(path)

        assert {:ok, img} =
                 Image.new_from_enum(enum, mode: :spool, content_length: len)

        assert {Image.width(img), Image.height(img), Image.bands(img)} ==
                 {Image.width(ref), Image.height(ref), Image.bands(ref)}
      end
    end

    test "requires content_length for mode: :spool" do
      {enum, _len} = chunked(img_path("puppies.jpg"))
      assert {:error, :content_length_required} =
               Image.new_from_enum(enum, mode: :spool)
    end

    test "unknown mode returns an error tuple" do
      {enum, len} = chunked(img_path("puppies.jpg"))

      assert {:error, {:invalid_mode, :bogus}} =
               Image.new_from_enum(enum, mode: :bogus, content_length: len)
    end

    test "mode: :pipe ignores spool-only opts and still decodes" do
      {enum, len} = chunked(img_path("puppies.jpg"))

      assert {:ok, _img} =
               Image.new_from_enum(enum, mode: :pipe, content_length: len, max_bytes: 1, timeout: 5)
    end

    # (4) :timeout watchdog — the ONLY liveness mechanism for a live-but-stalled producer (the
    # monitor only fires on death). A stalled feeder must yield {:error,_}, not hang.
    @tag timeout: 10_000
    test "seekable :timeout aborts a stalled feeder instead of hanging" do
      enum = Stream.resource(fn -> :s end, fn :s -> Process.sleep(:infinity) end, fn _ -> :ok end)

      assert {:error, _} =
               Image.new_from_enum(enum, mode: :spool, content_length: 1000, timeout: 300)
    end

    test "seekable rejects an invalid :timeout before doing any work" do
      assert {:error, :invalid_timeout} =
               Image.new_from_enum([<<>>], mode: :spool, content_length: 1, timeout: 0)
    end

    # :timeout aborts a producer that stalls AFTER partial delivery — not only one that delivers
    # nothing. A seek-heavy TIFF keeps its directory/strips at high offsets, so the loader blocks
    # reading a position past the frontier that never arrives. The watchdog (tied to the feeder's
    # lifetime, so it also covers reads triggered after new_from_enum/2 returns) must surface an
    # error within ~timeout rather than hang. The underlying read error is our ECANCELED abort.
    @tag timeout: 10_000
    test "seekable :timeout aborts a producer that stalls mid-delivery" do
      bytes = File.read!(img_path("boats.tif"))
      total = byte_size(bytes)
      half = binary_part(bytes, 0, div(total, 2))

      enum =
        Stream.resource(
          fn -> :half end,
          fn
            :half -> {[half], :stall}
            :stall -> Process.sleep(:infinity)
          end,
          fn _ -> :ok end
        )

      assert {:error, _} =
               Image.new_from_enum(enum, mode: :spool, content_length: total, timeout: 300)
    end

    # When the producer (enumerable) raises, the decode fails with the producer's reason wrapped in
    # {:producer_error, _}, not the downstream libvips read error — so callers can diagnose the
    # real cause. A seek-heavy TIFF guarantees the decode actually needs the withheld bytes.
    @tag timeout: 10_000
    test "seekable surfaces the producer's exception as the error reason" do
      bytes = File.read!(img_path("boats.tif"))
      total = byte_size(bytes)
      half = binary_part(bytes, 0, div(total, 2))

      enum =
        Stream.resource(
          fn -> :half end,
          fn
            :half -> {[half], :boom}
            :boom -> raise "upstream exploded"
          end,
          fn _ -> :ok end
        )

      assert {:error, {:producer_error, {%RuntimeError{message: "upstream exploded"}, _stack}}} =
               Image.new_from_enum(enum, mode: :spool, content_length: total)
    end

    for name <- ["sample.heic", "sample.avif"] do
      @tag :heif
      @tag timeout: 10_000
      test "decodes #{name} fed incrementally (seekable)" do
        path = img_path(unquote(name))
        # Clear opt-in failure if VIX_TEST_HEIF is set but the format isn't actually supported.
        case Vix.Vips.Foreign.find_load(path) do
          {:ok, _} -> :ok
          _ -> flunk("VIX_TEST_HEIF set but libvips cannot load #{unquote(name)}")
        end

        {:ok, ref} = Image.new_from_file(path)
        {enum, len} = chunked(path)

        assert {:ok, img} =
                 Image.new_from_enum(enum, mode: :spool, content_length: len)

        assert {Image.width(img), Image.height(img)} ==
                 {Image.width(ref), Image.height(ref)}
      end
    end

    # :auto WITH a length must use the spool — proven by the 300ms timeout watchdog, which ONLY the
    # spool path has. Routing matters: a stalled infinite stream errors fast on the spool (watchdog),
    # but on the pipe path it HANGS (the pipe feeder blocks on the first never-arriving chunk) until
    # the 10s ExUnit tag. Asserting the error arrives FAST (< 2s) distinguishes them — a regression
    # that routed :auto+length to the pipe would fail by timeout instead of passing for free.
    @tag timeout: 10_000
    test "mode: :auto with content_length uses the spool (fast watchdog, not a pipe hang)" do
      enum = Stream.resource(fn -> :s end, fn :s -> Process.sleep(:infinity) end, fn _ -> :ok end)

      {elapsed_us, result} =
        :timer.tc(fn ->
          Image.new_from_enum(enum, mode: :auto, content_length: 1000, timeout: 300)
        end)

      assert {:error, _} = result

      assert elapsed_us < 2_000_000,
             "expected the spool watchdog (~300ms); got #{elapsed_us}µs (routed to the pipe?)"
    end

    # :auto WITHOUT a length falls back to the streaming pipe (decodes seek-heavy TIFF via
    # read_to_memory) and logs the fallback at debug. capture_log MUST force :debug or it captures
    # nothing and the assertion passes vacuously. test_helper.exs sets the global Logger level to
    # :warning; we must temporarily lower it to :debug and restore on exit. Logger.configure/1 is
    # global state, but this test is the only one in the suite that needs sub-warning capture, so
    # the race window is negligible in practice.
    test "mode: :auto without content_length falls back to the pipe and logs at debug" do
      prev_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: prev_level) end)

      {enum, _len} = chunked(img_path("boats.tif"))
      {:ok, ref} = Image.new_from_file(img_path("boats.tif"))

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert {:ok, img} = Image.new_from_enum(enum, mode: :auto)

          assert {Image.width(img), Image.height(img)} ==
                   {Image.width(ref), Image.height(ref)}
        end)

      assert log =~ "mode: :auto with no content_length"
    end

    # content_length: 0 is a valid empty-body length (not "no length"): it routes to the spool, which
    # finalizes immediately, and the empty source then fails as a normal decode error.
    test "mode: :auto with content_length: 0 routes to the spool (empty-body decode error)" do
      assert {:error, _} = Image.new_from_enum([<<>>], mode: :auto, content_length: 0)
    end

    # :auto only softens the MISSING-length case; an over-max length still errors (cap respected).
    test "mode: :auto with content_length over max_bytes still errors" do
      {enum, len} = chunked(img_path("puppies.jpg"))

      assert {:error, :content_length_too_large} =
               Image.new_from_enum(enum, mode: :auto, content_length: len, max_bytes: 1)
    end
  end
end
