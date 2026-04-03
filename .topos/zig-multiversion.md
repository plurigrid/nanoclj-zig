# Zig Multi-Version Development

## Toolchain Layout

```
.zig-toolchains/
  zig-aarch64-macos-0.16.0-dev.3070+b22eb176b/   # dev build from ziglang.org/builds/
```

Nix provides 0.15.2: `/nix/store/...-zig-0.15.2/bin/zig`

## Compatibility Layer: `src/compat.zig`

Two breaking changes between 0.15 → 0.16:

### ArrayListUnmanaged initialization
- **0.15**: `std.ArrayListUnmanaged(T){}` (zero-init struct)
- **0.16**: removed — use `std.ArrayListUnmanaged(T).empty` (explicit sentinel)
- **Compat**: `compat.emptyList(T)` dispatches via `@hasDecl(L, "empty")`

### Mutex
- **0.15**: `std.Thread.Mutex` — struct with `.lock()` / `.unlock()`
- **0.16**: `std.Thread.Mutex` removed. `std.atomic.Mutex` is `enum(u8)` with `tryLock`/`unlock` only. `std.Io.Mutex` has `lock(io)` but requires async Io context.
- **Compat**: `compat.Mutex` wraps both. On 0.16, spins via `tryLock` + `spinLoopHint`. When Zig 0.16 stabilizes with `std.Io`, swap to fiber-aware `Io.Mutex`.

## Testing Both Versions

```sh
# 0.15 (nix)
/nix/store/...-zig-0.15.2/bin/zig build test --summary all

# 0.16-dev (local toolchain)
.zig-toolchains/zig-aarch64-macos-0.16.0-dev.3070+b22eb176b/zig build test --summary all
```

Both must pass 45/45 tests.

## 0.16 Migration Path

When 0.16 stabilizes:
1. Drop 0.15 `@hasDecl` branches from `compat.zig`
2. Replace `compat.Mutex` spinlock with `std.Io.Mutex` (requires threading `Io` parameter)
3. Replace `std.Thread.spawn` in `thread_peval.zig` with `Io.async` fibers
4. Drop the coarse Mutex entirely — fibers don't need it (cooperative scheduling)
5. Use per-fiber GC arenas instead of shared GC + lock

## .gitignore

`.zig-toolchains/` is gitignored — each dev downloads their own.
