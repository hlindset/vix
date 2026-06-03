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

| `mode:` | `content_length` valid (non-negative int ≤ `max_bytes`) | nil / absent | invalid (negative / > `max_bytes`) |
|---|---|---|---|
| **`:pipe`** *(default)* | ignored → pipe | pipe | ignored → pipe |
| **`:spool`** | spool (overlap + seek) | `{:error, :content_length_required}` | `{:error, …}` |
| **`:auto`** | spool (overlap + seek) | pipe + `Logger.debug` | `{:error, …}` |

Design constraints captured by the table:

- **Default is `:pipe`.** Bare `new_from_enum(enum)` is byte-for-byte the current behavior.
- **`:auto` degrades to pipe *only* when `content_length` is `nil` or absent.** Presence is the
  switch: any value that is *present* — including a negative, over-`max_bytes`, or non-integer one —
  is routed to the spool path's validation and errors there, identical to `:spool`. This preserves
  the `max_bytes` safety cap and surfaces genuine caller bugs. `:auto` means "use a length if I have
  one," not "swallow anything"; it does **not** sniff malformed values back to the pipe.
- **`content_length: 0` is a valid (empty-body) length, not "no length."** It is non-`nil`, so under
  `:auto`/`:spool` it routes to the spool, which already handles zero-length bodies deliberately
  (`feed_spool/3` finalizes without pulling the enum). Decoding a zero-byte source then fails as a
  normal "no image" decode error — the correct outcome for an empty body. It does **not** fall back
  to the pipe.
- **`:pipe` + a `content_length` is silently ignored** (the caller explicitly chose pipe). Likewise
  `max_bytes:`/`timeout:` are spool-only and ignored under `:pipe` (and under `:auto` when it takes
  the pipe branch) — these keys are dropped before the loader sees them. No error.

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

- `:pipe` also runs `drop_spool_opts/1` as hygiene, not hard necessity: `validate_options/1` only
  checks `Keyword.keyword?` and `operation_call` silently skips keys the loader doesn't recognize,
  so leftover spool opts are harmless today. Dropping them avoids a stray `content_length:`
  colliding with a real loader option of the same name and keeps the loader's option set clean.
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
- `:auto` / `:spool` with `content_length: 0` → spool path; decodes the empty body and fails as a
  normal decode error (not a validation error, not a pipe fallback).
- Unknown mode → `{:error, {:invalid_mode, value}}`. This intentionally carries the offending value
  (diverging from the bare-atom errors above) since a bad mode is a static caller mistake worth
  echoing back; it stays an error tuple rather than raising, to keep the `{:ok, _} | {:error, _}`
  contract uniform.
- `:auto`→pipe and `:pipe` decode failures propagate the pipe path's existing error tuples.

## Testing

`test/vix/vips/image_test.exs` (extend existing seekable coverage, retargeted to `mode:`):

- `mode: :spool` + `content_length` → decodes (existing spool assertions, retargeted from
  `seekable: true`).
- `mode: :spool` + no length → `{:error, :content_length_required}`.
- `mode: :auto` + `content_length` → **must prove the spool path by behavior, not just "it decodes."**
  A plain decode of a fully-fed enum is indistinguishable from the pipe, so a routing regression
  (`:auto`+length silently going to the pipe) would pass green. Distinguish spool from pipe in at
  least one test: either mirror the overlap test in `source_spool_test.exs` (park a decoder before
  the body is fully written, assert it unblocks on later writes), or pass `timeout:` (honored only by
  the spool) and assert the watchdog fires.
- `mode: :auto` + no length → uses pipe; decodes JPEG, TIFF, and AVIF correctly and does **not**
  error. Assert the fallback log with
  `ExUnit.CaptureLog.capture_log([level: :debug], fn -> ... end)` — without forcing the level the
  capture is vacuous (debug is below the default level) and the assertion would pass for the wrong
  reason.
- `mode: :auto` + length > `max_bytes` → still `{:error, :content_length_too_large}` (cap respected).
- `mode: :auto` + `content_length: 0` → routes to spool; assert the empty-body decode-error result
  (pins the "0 is a length, not a fallback trigger" decision).
- `mode: :pipe` + `content_length:` / `max_bytes:` / `timeout:` → decodes via pipe with the spool
  opts ignored (guards `drop_spool_opts/1`; otherwise nothing tests the pipe branch against a leaked
  spool opt).
- Unknown `mode:` → `{:error, {:invalid_mode, _}}`.
- Binary-suffix backward-compat: `new_from_enum(enum, "[shrink=2]")` (non-list opts) still routes to
  the pipe — guards the new `is_list/1` dispatch from regressing the documented suffix-string API.
- Default (no `mode:`) → pipe, unchanged behavior.

Reuse the existing fixtures (`puppies.jpg`, `boats.tif`, `sample.avif`); HEIF stays env-gated behind
`VIX_TEST_HEIF`.

## Documentation

Rewrite the `@doc` streaming section in `new_from_enum/2` (retitle the `## Seekable input` heading to
`## Source mode`):

- Document `mode:` with the three values and the semantics table.
- Keep the `content_length:` / `max_bytes:` / `timeout:` option docs, noting they apply to `:spool`
  and `:auto`-with-length and are **ignored under `:pipe`** (and under `:auto` when it takes the pipe
  branch).
- Caveat under `:auto`, stated precisely so it is not misread as "no overlap": *with no length,
  forward formats (JPEG/PNG) still stream with overlap through the pipe; seek-heavy formats
  (TIFF/AVIF) are `read_to_memory`'d by libvips first (no overlap).*
- **Observability:** state that the `:auto`→pipe fallback logs at `Logger.debug` **by design** —
  `:auto` is an opt-in to best-effort, so a missing length is an expected, non-alarming outcome, and
  for some origins it would fire on every request (`info` would be noise). A caller who must
  *guarantee* overlap should use `mode: :spool` (which errors on a missing length); a caller who
  wants to *detect* the degraded path can check `content_length` before calling.
- Note that, with `seekable:` removed, a stale `seekable: true` key is now an unknown option: it is
  silently skipped by the loader and the call defaults to `mode: :pipe`. Acceptable on an unreleased
  branch; documented so the behavior is pinned, not accidental.
- Update the concurrency/resource-limits note to say it applies to the spool path (`:spool`, or
  `:auto` when a length is supplied).

## Open question (reviewer-contested)

Two of three spec reviewers flagged that `Logger.debug` for the `:auto`→pipe fallback is invisible in
a production server (debug is off by default) — exactly the perf-sensitive proxy audience in the
motivation. The counter-argument (held above): `:auto` is an explicit opt-in to best-effort, so the
fallback is *expected*, and `info`-level would be per-request noise for length-less origins. Decision
held at `debug` + prominent docs + the `mode: :spool` force-error escape hatch. Revisit if telemetry
is ever added to Vix (no dependency today).

## Out of scope

- True unknown-length **overlap** (imgproxy-style growing chunk-list with blocking `SEEK_END`).
  Empirically buys nothing over the pipe for unknown length; explicitly not pursued.
- Any change to the spool or pipe internals, the NIF surface, or the C code.
- Intent-flavored mode names (`:stream`/`:seek`); `:pipe`/`:spool` chosen for module-name
  consistency.
