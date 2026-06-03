# `Image.new_from_enum/2` source mode — `:pipe | :spool | :auto`

**Status:** design
**Date:** 2026-06-03
**Builds on:** [2026-06-02-source-spool-design.md](2026-06-02-source-spool-design.md)

## Motivation

`new_from_enum/2` currently selects its libvips source strategy with a boolean
`seekable:` option:

- absent / `false` → **pipe** path (`Vix.SourcePipe`, read-once OS pipe, the original behavior)
- `true` → **spool** path (`Vix.SourceSpool`, seekable in-memory buffer with download/decode
  overlap), which **requires** `content_length`

The gap: a caller whose origin does not provide a `Content-Length` (chunked transfer encoding,
some CDNs/proxies) cannot use `seekable: true` at all — it returns `{:error, :content_length_required}`.
Such a caller wants a single call site that uses the spool when a length is available and
degrades gracefully when it is not, rather than branching on the header themselves.

This spec adds that graceful degradation and, in the process, replaces the `seekable:` boolean
with a clearer three-valued `mode:` option.

## Decision: `mode:` replaces `seekable:`

The source strategy becomes a single atom-enum option:

```elixir
Image.new_from_enum(enum, mode: :pipe | :spool | :auto, content_length: n, ...)
```

Rationale for `mode:` over `seekable: true | false | :auto`:

- One coherent type (atom enum) instead of a boolean-or-atom union.
- `:auto` reads naturally as a mode; `seekable: :auto` read as a type confusion.
- `:spool` names the strict overlap path explicitly and matches the public `Vix.SourceSpool`
  module, keeping the vocabulary consistent.

`seekable:` exists only on the unreleased `source-spool-seekable-enum` branch, so it is **replaced
outright** — no deprecation shim, no external migration. Internal tests and docs move to `mode:`.

## Semantics

| `mode:` | `content_length` valid (positive int ≤ `max_bytes`) | nil / absent | invalid (negative / > `max_bytes`) |
|---|---|---|---|
| **`:pipe`** *(default)* | ignored → pipe | pipe | ignored → pipe |
| **`:spool`** | spool (overlap + seek) | `{:error, :content_length_required}` | `{:error, …}` |
| **`:auto`** | spool (overlap + seek) | pipe + `Logger.debug` | `{:error, …}` |

Design constraints captured by the table:

- **Default is `:pipe`.** Bare `new_from_enum(enum)` is byte-for-byte the current behavior.
- **`:auto` only softens the *missing-length* case.** A negative or over-`max_bytes` length still
  errors under `:auto`, identical to `:spool`. This preserves the `max_bytes` safety cap and
  surfaces genuine caller bugs — `:auto` is "use a length if I have a good one," not "swallow
  anything."
- **`:pipe` + a `content_length` is silently ignored** (the caller explicitly chose pipe). No error.

## Why pipe-delegation is the `:auto` fallback

This was settled empirically during design (callback-trace instrumentation of the spool, plus
a read of imgproxy's own source). The findings:

1. **The libvips length probe (`SEEK_END` from `vips_source_test_features`) is unavoidable for any
   seekable source** — independent of access mode (`SEQUENTIAL` vs `RANDOM` produced identical
   callback sequences) and of `find_load_source` (bypassing it merely moved the probe into the
   loader). So overlap on a *seekable* source genuinely requires answering that probe instantly,
   which requires a known `content_length`. Without a length there is no seekable-with-overlap to be
   had — for us or for imgproxy (whose `VipsImgproxySource` wires both `read` and `seek`, hits the
   same probe, and blocks on `SeekEnd` for unknown length, i.e. no overlap).

2. **The existing pipe path already decodes unknown-length input universally**, verified against
   JPEG (forward, streams with overlap), and TIFF + AVIF (seek-heavy, libvips `read_to_memory`'s the
   source internally then decodes). No `content_length` required. (HEIF fails only where the build
   lacks an HEVC codec — equally on the spool and `new_from_buffer` paths; not a path limitation.)

Therefore the cheapest *and* best `:auto` fallback is to **delegate to the pipe path we already
ship and test**. Alternatives were rejected:

- *Elixir buffer + `new_from_buffer`*: builds a full copy in the BEAM heap, no overlap for any
  format — strictly worse than the pipe.
- *C "wait()" redesign (imgproxy-style chunk-list / blocking `SEEK_END`)*: most work, touches
  reviewed C, and buys nothing the pipe does not already provide for unknown length.

`:auto`→pipe keeps forward-format overlap for free and lets libvips manage memory for seek-heavy
formats.

## Implementation

All changes are in `lib/vix/vips/image.ex`. **No C changes. The spool and pipe internals are
untouched** — this is purely a routing addition.

Replace the boolean dispatch in `new_from_enum/2`:

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

defp dispatch_enum(:auto, enum, opts) do
  case Keyword.get(opts, :content_length) do
    nil ->
      Logger.debug(fn ->
        "Vix.new_from_enum: mode: :auto with no content_length — using streaming pipe (no seek-overlap)"
      end)
      new_from_enum_pipe(enum, drop_spool_opts(opts))

    _len ->
      new_from_enum_spool(enum, opts)   # existing validation handles negative / > max_bytes
  end
end

defp dispatch_enum(other, _enum, _opts), do: {:error, {:invalid_mode, other}}

# Spool-only opts must not reach the loader / validate_options on the pipe path.
defp drop_spool_opts(opts), do: Keyword.drop(opts, [:content_length, :max_bytes, :timeout])
```

Notes:

- `:pipe` also runs `drop_spool_opts/1` so a stray `content_length:` (ignored per the table) cannot
  reach `validate_options/1` or the loader.
- `:auto`-with-length routes to `new_from_enum_spool/2` unchanged; its existing `validate_spool_length/2`
  produces `:content_length_required` / `:invalid_content_length` / `:content_length_too_large`. Note
  `:content_length_required` is unreachable from `:auto` (nil is handled before the spool call), but
  the negative / too-large errors are reachable and intended.
- An unknown `mode:` value returns `{:error, {:invalid_mode, other}}` rather than raising.
- `Logger` is already `require`d in `image.ex`. Use the zero-arg lazy form so the string is only
  built when debug logging is enabled.

## Error handling

- `:spool` with no length → `{:error, :content_length_required}` (unchanged).
- `:auto` / `:spool` with negative length → `{:error, :invalid_content_length}`.
- `:auto` / `:spool` with length > `max_bytes` → `{:error, :content_length_too_large}`.
- Unknown mode → `{:error, {:invalid_mode, value}}`.
- `:auto`→pipe and `:pipe` decode failures propagate the pipe path's existing error tuples.

## Testing

`test/vix/vips/image_test.exs` (extend existing seekable coverage, renamed to `mode:`):

- `mode: :spool` + `content_length` → decodes (existing spool assertions, retargeted from
  `seekable: true`).
- `mode: :spool` + no length → `{:error, :content_length_required}`.
- `mode: :auto` + `content_length` → uses spool (decodes; same assertions as `:spool`).
- `mode: :auto` + no length → uses pipe; decodes TIFF and AVIF and JPEG correctly and does **not**
  error. `ExUnit.CaptureLog` asserts the `Logger.debug` fallback line fires.
- `mode: :auto` + length > `max_bytes` → still `{:error, :content_length_too_large}` (cap respected).
- `mode: :pipe` + `content_length` → decodes via pipe, length ignored (no error).
- Unknown `mode:` → `{:error, {:invalid_mode, _}}`.
- Default (no `mode:`) → pipe, unchanged behavior.

Reuse the existing fixtures (`puppies.jpg`, `boats.tif`, `sample.avif`); HEIF stays env-gated behind
`VIX_TEST_HEIF`.

## Documentation

Rewrite the `## Seekable input` `@doc` section in `new_from_enum/2`:

- Document `mode:` with the three values and the semantics table.
- Keep the `content_length:` / `max_bytes:` / `timeout:` option docs (apply to `:spool` and
  `:auto`-with-length).
- Add a one-line caveat under `:auto`: seek-heavy formats without a length fall back to
  `read_to_memory` (no download/decode overlap).
- Update the concurrency/resource-limits note to say it applies to the spool path (`:spool`, or
  `:auto` when a length is supplied).

## Out of scope

- True unknown-length **overlap** (imgproxy-style growing chunk-list with blocking `SEEK_END`).
  Empirically buys nothing over the pipe for unknown length; explicitly not pursued.
- Any change to the spool or pipe internals, the NIF surface, or the C code.
- Intent-flavored mode names (`:stream`/`:seek`); `:pipe`/`:spool` chosen for module-name
  consistency.
