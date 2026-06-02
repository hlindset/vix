defmodule Vix.SourceSpoolTest do
  use ExUnit.Case, async: true

  alias Vix.SourceSpool

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
end
