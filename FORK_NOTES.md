# Fork Notes

This fork carries `libghostty-vt` work for app-agnostic terminal state transfer and callback integration.

## Why This Fork Exists

Consumers of `libghostty-vt` needed Ghostty-native support for:

- lossless binary terminal snapshot export/import
- C API callback parity for terminal state changes already modeled in Ghostty
- post-import state canonicalization so imported terminals are safe for immediate VT mutation

These changes belong in Ghostty core because they affect terminal correctness and the `libghostty-vt` ABI, not any one client or transport implementation.

## What Changed

### Binary snapshots

- Added whole-terminal binary snapshot export/import in `src/terminal/snapshot.zig`
- Exposed snapshot C APIs through `libghostty-vt`
- Included both screens, scrollback, cursor state, modes, colors, tabstops, pwd/title, and related terminal state
- Made import atomic by building temporary state and swapping on success

### Parser-boundary safety

- Added stream-idle checks so wrapper-level snapshot export rejects mid-sequence or mid-UTF-8 export requests

### Callback parity

- Added C shim support for:
  - `pwd_changed`
  - `notification`
  - `semantic_prompt`
  - `mode_changed`
  - `kitty_keyboard_changed`

These are exposed with Ghostty-native semantics rather than downstream-specific behavior.

### Import canonicalization

- Rebuilt out-of-band `RefCountedSet` bookkeeping after page import
- Recomputed derived row flags from imported cell state
- Fixed imported terminals so later VT operations like overwrite-at-cursor, clear-screen, and style mutation are immediately safe

This specifically addressed cross-target snapshot-import cases where imported terminals rendered correctly but could trap on later writes because imported page metadata was not fully canonicalized.

### Fuzzing

- Added a snapshot import AFL harness and seed corpus under `test/fuzz-libghostty`

## Validation

Verified in this fork with:

```sh
zig build test -Demit-macos-app=false -Dtest-filter=snapshot
zig build test -Demit-macos-app=false
```

Additional local validation included snapshot fuzzing setup and real integration against production snapshot fixtures.

## Downstream Expectations

Downstream consumers should still treat these as their responsibility:

- recreating any app-specific wrapper/handle state around a replaced terminal
- clearing client-side render caches if they keep incremental state outside Ghostty
- respecting the snapshot export parser-boundary contract

The Ghostty side guarantees that once `snapshotImport()` succeeds, the imported terminal is internally consistent for normal VT mutation paths.
