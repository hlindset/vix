# `new_from_enum` source `mode:` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unreleased `seekable:` boolean on `Image.new_from_enum/2` with a three-valued `mode: :pipe | :spool | :auto` option, where `:auto` uses the seekable spool when a `content_length` is supplied and gracefully delegates to the existing streaming pipe path when it is not.

**Architecture:** Pure routing change in `lib/vix/vips/image.ex`. A new private `dispatch_enum/3` selects between the existing `new_from_enum_pipe/2` and `new_from_enum_spool/2` based on `mode:`. No C changes; the spool and pipe internals are untouched. `:auto`-without-length logs at `Logger.debug` and strips spool-only opts before delegating to the pipe.

**Tech Stack:** Elixir, ExUnit (with `ExUnit.CaptureLog`), libvips via Vix NIFs.

**Spec:** `docs/superpowers/specs/2026-06-03-new-from-enum-mode-design.md`

**Build note:** No C is touched, so the existing `priv/vix.so` is reused — run tests with plain `mix test`. (The `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS` env is only needed when `c_src/` changes, which this plan does not.)

**Baseline:** Before Task 1, run `mix test` once and confirm a green baseline (HEIF cases skip unless `VIX_TEST_HEIF` is set) so Task 4's full-suite run isn't blocked by a pre-existing, unrelated failure.

---

## File Structure

- **Modify** `lib/vix/vips/image.ex`
  - `new_from_enum/2` (currently lines ~739–748): swap the `seekable:` boolean check for a `mode:` dispatch.
  - Add private `dispatch_enum/3`, `drop_spool_opts/1`.
  - Rewrite the `## Seekable input` `@doc` section (currently lines ~699–736) → `## Source mode`.
- **Modify** `test/vix/vips/image_test.exs`
  - `describe "new_from_enum seekable"` (lines ~535–649): rename to `"new_from_enum mode"`, retarget `seekable: true` → `mode: :spool`, add `:auto` / invalid-mode / pipe-ignores-spool-opts cases.
- **No other files change.** `lib/vix/source_spool.ex`'s moduledoc uses the word "seekable" descriptively (not the option) — leave it.

---

## Task 1: `mode:` dispatch for `:pipe` and `:spool`

Behavior-preserving rename of `seekable: true` → `mode: :spool`, plus `mode: :pipe` (the default) and an error for unknown modes. `:auto` is added in Task 2.

**Files:**
- Modify: `lib/vix/vips/image.ex` (`new_from_enum/2` ~739–748; add `dispatch_enum/3`, `drop_spool_opts/1`)
- Test: `test/vix/vips/image_test.exs` (`describe` block ~535–649)

- [ ] **Step 1: Retarget the existing seekable tests to `mode: :spool` (these will fail first)**

In `test/vix/vips/image_test.exs`, rename the describe block header on line ~535:

```elixir
  describe "new_from_enum mode" do
```

Then replace every `seekable: true` with `mode: :spool` inside that block. There are 7 occurrences (lines ~552, 562, 572, 577, 602, 625, 643), all inside this describe block — no `seekable: true` exists elsewhere in `lib`/`test`, so the global `sed` is safe. A safe scoped replacement:

```bash
# from repo root — only the describe block uses `seekable: true`
sed -i '' 's/seekable: true/mode: :spool/g' test/vix/vips/image_test.exs
```

Also rename the now-misleading test name on line ~559 and ~568 wording (optional but tidy):

```elixir
    test "requires content_length for mode: :spool" do
```

- [ ] **Step 2: Add a failing test for an unknown mode**

Add inside the describe block:

```elixir
    test "unknown mode returns an error tuple" do
      {enum, len} = chunked(img_path("puppies.jpg"))

      assert {:error, {:invalid_mode, :bogus}} =
               Image.new_from_enum(enum, mode: :bogus, content_length: len)
    end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/vix/vips/image_test.exs`
Expected: the **two driver tests** FAIL —
  - `requires content_length for mode: :spool`: old code ignores `:mode`, routes to the pipe, decodes → `{:ok, _}` instead of `{:error, :content_length_required}`.
  - `unknown mode returns an error tuple`: routes to the pipe, decodes → `{:ok, _}` instead of `{:error, {:invalid_mode, :bogus}}`.

The retargeted **decode** tests (`decodes <fmt> identically…`) do **not** fail here: with the old code `mode: :spool` is an unknown opt that `validate_options/1` accepts and `operation_call` silently skips, so they decode green via the pipe and the dimension assertions still hold. They are regression guards (green before *and* after), not red-phase drivers — this is expected, do not try to make them fail.

- [ ] **Step 4: Implement the `mode:` dispatch**

In `lib/vix/vips/image.ex`, replace the body of `new_from_enum/2` (the `if is_list(opts) and Keyword.get(opts, :seekable, false)` block, ~739–748) with:

```elixir
  def new_from_enum(enum, opts \\ []) do
    # opts may be a binary (backward-compat suffix string); only keyword opts select a mode.
    if is_list(opts) do
      {mode, opts} = Keyword.pop(opts, :mode, :pipe)
      dispatch_enum(mode, enum, opts)
    else
      new_from_enum_pipe(enum, opts)
    end
  end

  defp dispatch_enum(:pipe, enum, opts), do: new_from_enum_pipe(enum, drop_spool_opts(opts))
  defp dispatch_enum(:spool, enum, opts), do: new_from_enum_spool(enum, opts)
  defp dispatch_enum(other, _enum, _opts), do: {:error, {:invalid_mode, other}}

  # Spool-only opts must not leak to the loader on the pipe path. Hygiene, not strictly required
  # (validate_options/1 only checks Keyword.keyword? and operation_call skips unknown keys), but it
  # avoids a stray content_length: colliding with a real loader option of the same name.
  defp drop_spool_opts(opts), do: Keyword.drop(opts, [:content_length, :max_bytes, :timeout])
```

(`require Logger` is already present at the top of the module — it is used in Task 2.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/vix/vips/image_test.exs`
Expected: PASS, including the pre-existing binary-suffix test (`new_from_enum(stream, "[shrink=2]")`, ~line 341) which guards the non-list dispatch branch.

- [ ] **Step 6: Add a smoke test that `:pipe` tolerates stray spool opts**

```elixir
    test "mode: :pipe ignores spool-only opts and still decodes" do
      {enum, len} = chunked(img_path("puppies.jpg"))

      assert {:ok, _img} =
               Image.new_from_enum(enum, mode: :pipe, content_length: len, max_bytes: 1, timeout: 5)
    end
```

Run: `mix test test/vix/vips/image_test.exs` → PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/vix/vips/image.ex test/vix/vips/image_test.exs
git commit -m "feat: mode: :pipe | :spool dispatch for new_from_enum (replaces seekable:)"
```

---

## Task 2: `:auto` mode (spool-if-length, else pipe)

**Files:**
- Modify: `lib/vix/vips/image.ex` (insert an `:auto` clause into `dispatch_enum/3`)
- Test: `test/vix/vips/image_test.exs` (`describe "new_from_enum mode"`)

- [ ] **Step 1: Write the failing `:auto` tests**

Add these inside the describe block. (`chunked/2` and `img_path/1` are already in scope.)

```elixir
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
    # nothing and the assertion passes vacuously.
    test "mode: :auto without content_length falls back to the pipe and logs at debug" do
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/vix/vips/image_test.exs`
Expected: FAIL. Without an `:auto` clause, `dispatch_enum(:auto, …)` hits the catch-all and returns `{:error, {:invalid_mode, :auto}}` for every case.

- [ ] **Step 3: Implement the `:auto` clause**

In `lib/vix/vips/image.ex`, insert this clause **between** `dispatch_enum(:spool, …)` and the `dispatch_enum(other, …)` catch-all:

```elixir
  defp dispatch_enum(:auto, enum, opts) do
    case Keyword.get(opts, :content_length) do
      nil ->
        Logger.debug(fn ->
          "Vix.Image.new_from_enum/2: mode: :auto with no content_length — " <>
            "using streaming pipe (no seek-overlap)"
        end)

        new_from_enum_pipe(enum, drop_spool_opts(opts))

      _len ->
        # Present length (incl. negative / over-max / non-integer) goes to the spool's validation,
        # which produces the right error. Only a nil/absent length degrades to the pipe.
        new_from_enum_spool(enum, opts)
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/vix/vips/image_test.exs`
Expected: PASS (all four `:auto` tests, plus the Task 1 tests still green).

- [ ] **Step 5: Commit**

```bash
git add lib/vix/vips/image.ex test/vix/vips/image_test.exs
git commit -m "feat: mode: :auto — spool when content_length given, else pipe fallback"
```

---

## Task 3: Rewrite the `@doc` for `mode:`

No test (documentation only); verify it compiles.

**Files:**
- Modify: `lib/vix/vips/image.ex` (the `@doc` streaming section, ~699–736)

- [ ] **Step 1: Replace the `## Seekable input` doc section**

In the `@doc` for `new_from_enum/2`, replace **lines 699–735** — from the heading line (exactly, including the suffix):

```
  ## Seekable input (`seekable: true`)
```

through the end of the `### Concurrency and resource limits` paragraph (the line ending `…a semaphore or worker pool gating entry into the decode.` on line 735), i.e. up to but **not** including the blank line 736 and the closing `"""` on line 737. Replace that whole span (heading + body + the `### Concurrency` subsection — leave no orphan heading or `(`seekable: true`)` suffix behind) with:

````markdown
  ## Source mode

  The `mode:` option selects how the enumerable is presented to libvips:

  | `mode:` | with a valid `content_length` | without `content_length` |
  | --- | --- | --- |
  | `:pipe` *(default)* | streams (length ignored) | streams |
  | `:spool` | seekable in-memory buffer, download/decode overlap | `{:error, :content_length_required}` |
  | `:auto` | same as `:spool` | falls back to `:pipe` (logs at `debug`) |

      # known length — overlap + seek (HEIF/AVIF/multi-page TIFF)
      Image.new_from_enum(stream, mode: :spool, content_length: byte_size)

      # length may be absent (e.g. chunked transfer encoding) — best effort
      Image.new_from_enum(stream, mode: :auto, content_length: maybe_length)

  - **`:pipe`** (default) feeds the bytes through a read-once OS pipe. Forward formats (JPEG, PNG)
    stream with overlap; seek-heavy formats are `read_to_memory`'d by libvips. `content_length:`,
    `max_bytes:`, and `timeout:` are spool-only and ignored here.
  - **`:spool`** spools the bytes into a native seekable buffer (`Vix.SourceSpool`) that libvips can
    seek over while data is still arriving. Requires `content_length:`.
  - **`:auto`** uses the spool when `content_length` is present and falls back to `:pipe` when it is
    `nil`/absent — for origins that may not send a `Content-Length`. With no length, forward formats
    still stream with overlap; seek-heavy formats (TIFF, AVIF) are `read_to_memory`'d (no overlap).
    The fallback logs at `Logger.debug` (an expected, opted-in outcome). To *guarantee* overlap, use
    `:spool` (which errors on a missing length); to *detect* the fallback, check `content_length`
    before calling. Note `content_length: 0` is a valid empty-body length (routes to the spool),
    not "no length".

  > The former `seekable: true` option is removed. A stray `seekable:` key is now an unknown option,
  > silently ignored, so such a call defaults to `mode: :pipe`.

  Options (apply to `:spool`, and `:auto` when a length is supplied):

    * `content_length:` - exact total byte size. **Required** for `:spool`. A stable length is
      mandatory for a seekable source.
    * `max_bytes:` - reject a declared `content_length` larger than this. **Defaults to 100 MB**
      (override globally with `config :vix, source_spool_max_bytes: bytes`, or per call). Set it
      deliberately when `content_length` comes from an untrusted source such as a `Content-Length`
      header, otherwise large bodies get `{:error, :content_length_too_large}`.
    * `timeout:` - maximum milliseconds for the producer to deliver the full body. Covers the
      producer's whole lifetime, including reads triggered by lazy decoding *after* this function
      returns; on expiry the source is aborted and the producer killed, so any pending or later
      decode fails rather than hanging.

  For `:spool` (and `:auto` with a length), the entire input is held in RAM (`~content_length`
  bytes) for the lifetime of the decode. If the producer raises, the decode fails with the
  producer's reason wrapped in `{:producer_error, _}` (the producer runs in a separate process).

  ### Concurrency and resource limits (spool path)

  Each in-flight spool decode holds `content_length` bytes resident **and** parks one dirty-IO
  scheduler thread while it waits for bytes. Bound concurrency at the call site — Vix deliberately
  does not, because the right limit depends on your RAM budget (`N × content_length`), the dirty-IO
  scheduler pool (`+SDio`, default ~10), and libvips' own per-operation threads
  (`Vix.Vips.concurrency_set/1`). For batches, gate with
  `Task.async_stream(streams, fun, max_concurrency: System.schedulers_online() * 2, timeout: ...)`;
  for a request path, a semaphore or worker pool gating entry into the decode.
````

- [ ] **Step 2: Verify it compiles cleanly**

Run: `mix compile --warnings-as-errors`
Expected: compiles, no warnings. (No C rebuild — Elixir only.)

- [ ] **Step 3: Commit**

```bash
git add lib/vix/vips/image.ex
git commit -m "docs: document new_from_enum mode: :pipe | :spool | :auto"
```

---

## Task 4: Full-suite verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full image test file and the spool tests**

Run: `mix test test/vix/vips/image_test.exs test/vix/source_spool_test.exs`
Expected: all PASS. (HEIF cases stay skipped unless `VIX_TEST_HEIF` is set.)

- [ ] **Step 2: Run the whole suite to catch any stale `seekable:` reference**

Run: `mix test`
Expected: all PASS. Grep guard:

```bash
grep -rn "seekable: true" lib test && echo "STALE seekable: usage found" || echo "clean"
```

Expected: `clean` (the only remaining "seekable" is the descriptive word in `source_spool.ex`'s moduledoc).

- [ ] **Step 3: Format**

Run: `mix format lib/vix/vips/image.ex test/vix/vips/image_test.exs`

- [ ] **Step 4: Final commit if formatting changed anything**

```bash
git add -A && git commit -m "chore: mix format" || true
```

---

## Self-Review

**Spec coverage:**
- `mode: :pipe | :spool | :auto` semantics table → Task 1 (`:pipe`/`:spool`) + Task 2 (`:auto`). ✓
- Default `:pipe`, byte-for-byte current behavior → Task 1 (existing binary-suffix + default tests stay green). ✓
- `:auto` degrades only on nil/absent; present-but-bad errors → Task 2 `:auto` clause (`_len ->` to spool) + over-max test. ✓
- `content_length: 0` → spool empty-body → Task 2 test. ✓
- `drop_spool_opts` hygiene → Task 1 impl + smoke test. ✓
- `Logger.debug` fallback, level-forced capture → Task 2 test. ✓
- Spool-vs-pipe routing proof for `:auto`+length → Task 2 timeout-watchdog test. ✓
- Error handling (`:content_length_required`, `:invalid_content_length`, `:content_length_too_large`, `{:invalid_mode, _}`) → Task 1 retargeted tests + Task 2 over-max + unknown-mode. ✓
- `@doc` rewrite incl. forward-formats-still-overlap, observability-by-design, opts-ignored-under-pipe → Task 3. ✓
- Backward-compat binary suffix → pre-existing test guarded by Task 1 dispatch; verified in Task 4 grep. ✓

**Placeholder scan:** none — every code/test step shows full code; doc step shows the full replacement text.

**Type/name consistency:** `dispatch_enum/3`, `drop_spool_opts/1`, `new_from_enum_pipe/2`, `new_from_enum_spool/2`, `chunked/2`, `img_path/1` used consistently across tasks; the `Logger.debug` message substring asserted in Task 2 (`"mode: :auto with no content_length"`) matches the string emitted in the Task 2 implementation.
