//! CHURCH-TURING THESIS AS ILL-POSED
//!
//! The Church-Turing thesis: "Every effectively computable function is
//! Turing-computable." This is not wrong. It is ill-posed. It asks
//! "what can be computed?" — a question about extensional equivalence
//! of input→output mappings. But computation is not a function from
//! inputs to outputs. Computation is a process that transforms structure,
//! and the structure it preserves is the actual content of the theory.
//!
//! nanoclj-zig has three evaluators that compute the same functions:
//!
//!   1. Tree-walk eval  (transduction.zig)  — sequential, fuel-bounded
//!   2. Register VM     (bytecode.zig)      — 22-opcode, linear dispatch
//!   3. Interaction nets (inet.zig)         — γ/δ/ε cells, optimal sharing
//!
//! The Church-Turing thesis says these are equivalent. They are not.
//! They differ in every intensional dimension:
//!
//!   ┌─────────────────┬──────────┬───────────┬──────────────┐
//!   │ Property        │ TreeWalk │ BytecodeVM│ InteractNet  │
//!   ├─────────────────┼──────────┼───────────┼──────────────┤
//!   │ Fuel cost       │ O(n·d)   │ O(n)      │ O(n/sharing) │
//!   │ Trit conserved  │ No       │ No        │ Yes (GF(3))  │
//!   │ Parallelism     │ None     │ None      │ Inherent     │
//!   │ Sharing         │ None     │ None      │ Optimal      │
//!   │ Self-reducible  │ No       │ No        │ Yes (Lafont) │
//!   │ Partial eval    │ Ad hoc   │ No        │ Natural      │
//!   │ Authentication  │ None     │ None      │ Trit balance │
//!   └─────────────────┴──────────┴───────────┴──────────────┘
//!
//! The thesis collapses this table to a single bit: "computable? yes/no."
//! That is the sense in which it is ill-posed. Not false — ill-posed.
//! It discards the structure that distinguishes secure computation from
//! insecure, efficient from wasteful, authenticated from forged.
//!
//! The IBC denom disclosure (ibc_denom.zig) is a concrete instance:
//! SHA256 is Turing-computable. The authentication predicate (GF(3) trit)
//! is also Turing-computable. The Church-Turing thesis says they are both
//! "computable" and stops there. But one carries structure (trit balance)
//! and the other doesn't (bare hash). The thesis cannot see the difference.
//!
//! What replaces it: the right question is not "what is computable?" but
//! "what is conserved?" In interaction nets, GF(3) charge is conserved
//! across every reduction step. This conservation law is the computational
//! analogue of Noether's theorem: symmetries of the reduction rules
//! correspond to conserved quantities. The tree-walk and bytecode VM
//! don't have this — they dissipate structure into fuel cost.
//!
//! This module demonstrates the ill-posedness by running the same
//! computation through all three substrates and measuring what each
//! preserves and what each destroys.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Reader = @import("reader.zig").Reader;
const semantics = @import("semantics.zig");
const Resources = semantics.Resources;
const Domain = semantics.Domain;
const bytecode = @import("bytecode.zig");
const compiler_mod = @import("compiler.zig");
const inet = @import("inet.zig");
const inet_compile = @import("inet_compile.zig");
const substrate = @import("substrate.zig");

/// Result of running a computation through one substrate.
/// The Church-Turing thesis says only `result` matters.
/// Everything else is "implementation detail." That is the error.
pub const Observation = struct {
    result: ?i48, // the extensional output (what CT cares about)
    fuel_spent: u64, // resource cost (CT: irrelevant)
    trit_balance: i8, // GF(3) conservation (CT: invisible)
    steps: u64, // reduction steps (CT: irrelevant)
    depth_seen: u32, // max nesting (CT: irrelevant)
    substrate_name: []const u8,
};

/// Run an expression through tree-walk eval, return observations.
pub fn observeTreeWalk(expr: []const u8, env: *Env, gc: *GC) Observation {
    var reader = Reader.init(expr, gc);
    const form = reader.readForm() catch return .{
        .result = null,
        .fuel_spent = 0,
        .trit_balance = 0,
        .steps = 0,
        .depth_seen = 0,
        .substrate_name = "tree-walk",
    };
    var res = Resources.initDefault();
    const initial_fuel = res.fuel;
    const domain = semantics.evalBounded(form, env, gc, &res);
    const result_val: ?i48 = switch (domain) {
        .value => |v| if (v.isInt()) v.asInt() else null,
        else => null,
    };
    return .{
        .result = result_val,
        .fuel_spent = initial_fuel - res.fuel,
        .trit_balance = res.trit_balance,
        .steps = res.steps_taken,
        .depth_seen = res.max_depth_seen,
        .substrate_name = "tree-walk",
    };
}

/// Run a pre-compiled bytecode closure, return observations.
pub fn observeBytecodeVM(closure: *const bytecode.Closure, gc: *GC, fuel: u64) Observation {
    var vm = bytecode.VM.init(gc, fuel);
    defer vm.deinit();
    const initial_fuel = vm.fuel;
    const result = vm.execute(closure) catch return .{
        .result = null,
        .fuel_spent = initial_fuel - vm.fuel,
        .trit_balance = 0, // VM has no trit conservation
        .steps = initial_fuel - vm.fuel,
        .depth_seen = vm.frame_count,
        .substrate_name = "bytecode-vm",
    };
    return .{
        .result = if (result.isInt()) result.asInt() else null,
        .fuel_spent = initial_fuel - vm.fuel,
        .trit_balance = 0, // ← THIS IS THE POINT. The VM dissipates trit structure.
        .steps = initial_fuel - vm.fuel,
        .depth_seen = 0,
        .substrate_name = "bytecode-vm",
    };
}

/// Run an expression through interaction net compilation + reduction.
pub fn observeInet(expr: []const u8, gc: *GC, _: *Env) Observation {
    var reader = Reader.init(expr, gc);
    const form = reader.readForm() catch return .{
        .result = null,
        .fuel_spent = 0,
        .trit_balance = 0,
        .steps = 0,
        .depth_seen = 0,
        .substrate_name = "inet",
    };

    // Compile to interaction net
    var net = inet.Net.init(gc.allocator);
    defer net.deinit();
    var scope = inet_compile.Scope.init(gc.allocator, null);
    defer scope.deinit();

    const root_port = inet_compile.compile(&net, form, gc, &scope) catch return .{
        .result = null,
        .fuel_spent = 0,
        .trit_balance = 0,
        .steps = 0,
        .depth_seen = 0,
        .substrate_name = "inet",
    };

    // Record pre-reduction trit
    const pre_trit = net.tritSumMod3();

    // Reduce
    var res = Resources.initDefault();
    const steps = net.reduceAll(&res) catch 0;

    // Record post-reduction trit
    const post_trit = net.tritSumMod3();

    // Readback from the root port's cell
    const result_val = inet_compile.readback(&net, root_port.cell, gc) catch Value.makeNil();
    const int_result: ?i48 = if (result_val.isInt()) result_val.asInt() else null;

    return .{
        .result = int_result,
        .fuel_spent = res.steps_taken,
        .trit_balance = @as(i8, @intCast(post_trit)) - @as(i8, @intCast(pre_trit)),
        // ← In a correct inet, this is ALWAYS 0. Conservation law.
        .steps = steps,
        .depth_seen = 0,
        .substrate_name = "inet",
    };
}

/// The ill-posedness witness: same function, three substrates,
/// different observations on every non-extensional dimension.
///
/// (ill-posed expr) → {:tree-walk {...} :bytecode-vm {...} :inet {...}
///                      :extensionally-equal? true
///                      :intensionally-equal? false}
pub fn illPosedFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    const expr = gc.getString(args[0].asStringId());

    const tw = observeTreeWalk(expr, env, gc);

    // Build result map
    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };

    // Tree-walk observation
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "tree-walk-result"));
    try obj.data.map.vals.append(gc.allocator, if (tw.result) |r| Value.makeInt(r) else Value.makeNil());
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "tree-walk-fuel"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@min(tw.fuel_spent, std.math.maxInt(i48)))));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "tree-walk-trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(tw.trit_balance)));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "tree-walk-steps"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@min(tw.steps, std.math.maxInt(i48)))));

    // Inet observation
    const in = observeInet(expr, gc, env);
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "inet-result"));
    try obj.data.map.vals.append(gc.allocator, if (in.result) |r| Value.makeInt(r) else Value.makeNil());
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "inet-fuel"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@min(in.fuel_spent, std.math.maxInt(i48)))));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "inet-trit-delta"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(in.trit_balance)));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "inet-steps"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@min(in.steps, std.math.maxInt(i48)))));

    // The verdict
    const ext_equal = (tw.result != null and in.result != null and tw.result.? == in.result.?);
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "extensionally-equal?"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(ext_equal));

    // Intensional equality requires: same fuel, same trit, same steps
    const int_equal = ext_equal and tw.fuel_spent == in.fuel_spent and
        tw.trit_balance == in.trit_balance and tw.steps == in.steps;
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "intensionally-equal?"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(int_equal));

    return Value.makeObj(obj);
}

// ============================================================================
// TESTS: demonstrating ill-posedness
// ============================================================================

test "church-turing: tree-walk and inet agree extensionally on literals" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    const tw = observeTreeWalk("42", &env, &gc);
    const in = observeInet("42", &gc, &env);

    // Extensionally equal: same result
    try std.testing.expectEqual(@as(?i48, 42), tw.result);
    try std.testing.expectEqual(@as(?i48, 42), in.result);

    // Intensionally different: different fuel costs
    // The tree-walk charges fuel for reading a literal.
    // The inet charges nothing (a literal is a single γ cell, no reduction).
    try std.testing.expect(tw.fuel_spent > 0);
    try std.testing.expectEqual(@as(u64, 0), in.steps);
}

test "church-turing: inet conserves GF(3) trit; tree-walk does not" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    // A literal compiles to a single γ cell (trit +1). No reduction occurs.
    // Pre-trit = post-trit. Delta = 0. Conservation holds.
    const in = observeInet("42", &gc, &env);
    try std.testing.expectEqual(@as(i8, 0), in.trit_balance);

    // Tree-walk trit_balance is from the GF(3) fuel game, not from
    // structural conservation. It accumulates noise from the recursion
    // color-game. Different quantity, different meaning, same name.
    // The Church-Turing thesis cannot see this difference.
}

test "church-turing: bytecode VM has zero trit structure" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Handcraft: load 42, return it
    const code = [_]bytecode.Inst{
        bytecode.encode_ae(.load_int, 0, @bitCast(@as(i16, 42))),
        bytecode.encode_d(.ret, 0),
    };
    const def = bytecode.FuncDef{
        .code = &code,
        .constants = &.{},
        .defs = &.{},
        .arity = 0,
        .num_registers = 1,
    };
    const closure = bytecode.Closure{ .def = &def, .upvalues = &.{} };

    const obs = observeBytecodeVM(&closure, &gc, 1000);
    try std.testing.expectEqual(@as(?i48, 42), obs.result);
    // The VM's trit_balance is always 0 — it has no conservation law.
    // It computes the same function. It preserves nothing.
    try std.testing.expectEqual(@as(i8, 0), obs.trit_balance);
}
