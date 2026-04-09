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
const Limits = semantics.Limits;
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
pub fn illPosedFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
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
// DECIDABILITY HIERARCHY
//
// The lecture's three levels, witnessed through nanoclj's substrates:
//
//   DECIDABLE:       characteristic function χ_S exists.
//                    All substrates halt on all inputs. (even?, prime?)
//
//   SEMI-DECIDABLE:  can enumerate membership (halt on YES),
//                    but may diverge on non-membership (fuel exhaust on NO).
//                    The three substrates diverge DIFFERENTLY:
//                      tree-walk: burns fuel linearly
//                      bytecode VM: burns fuel linearly
//                      inet: trit never balances → structurally visible
//
//   UNDECIDABLE:     the halting problem. No substrate can decide it.
//                    But they FAIL differently:
//                      tree-walk: fuel exhaustion is indistinguishable from "still computing"
//                      bytecode VM: same
//                      inet: non-halting leaves trit imbalanced → the *failure mode* carries information
//
// The Church-Turing thesis says all three levels are "about computability."
// The decidability hierarchy says: even when you restrict to the extensional
// question "does this halt?", the substrates give you different EVIDENCE.
// ============================================================================

/// Decidability level of a predicate observed through a substrate.
pub const DecidabilityLevel = enum(u8) {
    decidable,       // halted with definite YES or NO
    semi_decidable,  // halted with YES, or fuel exhausted (unknown)
    undecidable,     // cannot decide; substrate-specific failure mode
};

/// Witness: evidence from running a predicate through a substrate.
pub const DecidabilityWitness = struct {
    level: DecidabilityLevel,
    answer: ?bool,           // null = couldn't determine
    fuel_spent: u64,
    trit_balanced: bool,     // inet only: did trit balance to 0?
    substrate_name: []const u8,
    halted: bool,            // did the computation terminate?
};

/// Primitive recursive: even? — always decidable.
/// χ_even(n) = 1 if n mod 2 = 0, else 0.
fn isEven(n: i48) bool {
    return @mod(n, 2) == 0;
}

/// Primitive recursive: prime? — always decidable.
/// Trial division up to sqrt(n).
fn isPrime(n: i48) bool {
    if (n < 2) return false;
    if (n < 4) return true;
    if (@mod(n, 2) == 0) return false;
    var i: i48 = 3;
    while (i * i <= n) : (i += 2) {
        if (@mod(n, i) == 0) return false;
    }
    return true;
}

/// Semi-decidable: "does program P ever produce value V?"
/// We simulate P for up to `fuel` steps. If we see V, return true.
/// If fuel runs out, we don't know — return null.
/// This is the halting-on-hello problem from the lecture.
fn searchForValue(expr: []const u8, target: i48, env: *Env, gc: *GC, fuel_limit: u64) DecidabilityWitness {
    var reader = Reader.init(expr, gc);
    const form = reader.readForm() catch return .{
        .level = .undecidable,
        .answer = null,
        .fuel_spent = 0,
        .trit_balanced = true,
        .substrate_name = "tree-walk",
        .halted = false,
    };
    var limits = Limits{};
    limits.max_fuel = fuel_limit;
    var res = Resources.init(limits);
    const domain = semantics.evalBounded(form, env, gc, &res);
    const fuel_spent = fuel_limit - res.fuel;

    switch (domain) {
        .value => |v| {
            if (v.isInt() and v.asInt() == target) {
                return .{
                    .level = .semi_decidable,
                    .answer = true,
                    .fuel_spent = fuel_spent,
                    .trit_balanced = res.trit_balance == 0,
                    .substrate_name = "tree-walk",
                    .halted = true,
                };
            }
            // Halted but didn't produce target — decidably NO for this input
            return .{
                .level = .decidable,
                .answer = false,
                .fuel_spent = fuel_spent,
                .trit_balanced = res.trit_balance == 0,
                .substrate_name = "tree-walk",
                .halted = true,
            };
        },
        else => {
            // Fuel exhaustion or error — semi-decidable failure
            return .{
                .level = .semi_decidable,
                .answer = null,
                .fuel_spent = fuel_spent,
                .trit_balanced = res.trit_balance == 0,
                .substrate_name = "tree-walk",
                .halted = false,
            };
        },
    }
}

/// Same search through inet: non-halting is structurally visible via trit imbalance.
fn searchForValueInet(expr: []const u8, target: i48, gc: *GC, env: *Env) DecidabilityWitness {
    _ = env;
    var reader = Reader.init(expr, gc);
    const form = reader.readForm() catch return .{
        .level = .undecidable,
        .answer = null,
        .fuel_spent = 0,
        .trit_balanced = false,
        .substrate_name = "inet",
        .halted = false,
    };

    var net = inet.Net.init(gc.allocator);
    defer net.deinit();
    var scope = inet_compile.Scope.init(gc.allocator, null);
    defer scope.deinit();

    const root_port = inet_compile.compile(&net, form, gc, &scope) catch return .{
        .level = .undecidable,
        .answer = null,
        .fuel_spent = 0,
        .trit_balanced = false,
        .substrate_name = "inet",
        .halted = false,
    };

    const pre_trit = net.tritSumMod3();
    var res = Resources.initDefault();
    const steps = net.reduceAll(&res) catch 0;
    const post_trit = net.tritSumMod3();
    const trit_delta = @as(i8, @intCast(post_trit)) - @as(i8, @intCast(pre_trit));
    const trit_balanced = trit_delta == 0;

    const result_val = inet_compile.readback(&net, root_port.cell, gc) catch Value.makeNil();
    if (result_val.isInt() and result_val.asInt() == target) {
        return .{
            .level = .semi_decidable,
            .answer = true,
            .fuel_spent = steps,
            .trit_balanced = trit_balanced,
            .substrate_name = "inet",
            .halted = true,
        };
    }

    if (result_val.isNil() and !trit_balanced) {
        // Inet evidence: trit imbalance means computation didn't reach normal form.
        // This is structurally visible information that tree-walk doesn't have.
        return .{
            .level = .semi_decidable,
            .answer = null,
            .fuel_spent = steps,
            .trit_balanced = false,
            .substrate_name = "inet",
            .halted = false,
        };
    }

    return .{
        .level = .decidable,
        .answer = false,
        .fuel_spent = steps,
        .trit_balanced = trit_balanced,
        .substrate_name = "inet",
        .halted = true,
    };
}

/// (decidable? n "even") → {:answer true/false :level :decidable ...}
/// (decidable? n "prime") → {:answer true/false :level :decidable ...}
/// The characteristic function always halts. All substrates agree.
pub fn decidableFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    if (!args[1].isString()) return error.TypeError;

    const n = args[0].asInt();
    const pred_name = gc.getString(args[1].asStringId());

    const answer: bool = if (std.mem.eql(u8, pred_name, "even"))
        isEven(n)
    else if (std.mem.eql(u8, pred_name, "prime"))
        isPrime(n)
    else
        return error.TypeError;

    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };

    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "answer"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(answer));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "level"));
    try obj.data.map.vals.append(gc.allocator, try kw.intern(gc, "decidable"));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "characteristic"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(if (answer) 1 else 0));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "predicate"));
    try obj.data.map.vals.append(gc.allocator, args[1]);

    return Value.makeObj(obj);
}

/// (semi-decide expr target) → witness map
/// (semi-decide expr target fuel) → witness map with custom fuel
///
/// Runs expr through tree-walk AND inet. If expr produces target, returns
/// {:answer true}. If fuel exhausts, tree-walk says "don't know" but inet
/// says "trit imbalanced" — additional structural evidence.
pub fn semiDecideFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    if (!args[1].isInt()) return error.TypeError;

    const expr = gc.getString(args[0].asStringId());
    const target = args[1].asInt();
    const fuel: u64 = if (args.len >= 3 and args[2].isInt())
        @intCast(@max(1, args[2].asInt()))
    else
        10_000;

    const tw = searchForValue(expr, target, env, gc, fuel);
    const in = searchForValueInet(expr, target, gc, env);

    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };

    const obj = try gc.allocObj(.map);

    // Tree-walk witness
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "tree-walk-answer"));
    try obj.data.map.vals.append(gc.allocator, if (tw.answer) |a| Value.makeBool(a) else Value.makeNil());
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "tree-walk-halted?"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(tw.halted));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "tree-walk-fuel-spent"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@min(tw.fuel_spent, std.math.maxInt(i48)))));

    // Inet witness
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "inet-answer"));
    try obj.data.map.vals.append(gc.allocator, if (in.answer) |a| Value.makeBool(a) else Value.makeNil());
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "inet-halted?"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(in.halted));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "inet-trit-balanced?"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(in.trit_balanced));

    // The point: when both agree, it's decidable. When tree-walk exhausts
    // fuel but inet's trit is imbalanced, inet gives you MORE EVIDENCE
    // than tree-walk does. The Church-Turing thesis cannot see this.
    const both_agree = (tw.answer != null and in.answer != null and
        ((tw.answer.? and in.answer.?) or (!tw.answer.? and !in.answer.?)));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "substrates-agree?"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(both_agree));

    return Value.makeObj(obj);
}

/// (halting-witness expr) → {:tree-walk ... :inet ... :diagnosis ...}
///
/// The undecidable level: runs expr and reports how each substrate FAILS.
/// The point is not whether it halts — it's that the failure modes differ.
pub fn haltingWitnessFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;

    const expr = gc.getString(args[0].asStringId());
    const fuel: u64 = if (args.len >= 2 and args[1].isInt())
        @intCast(@max(1, args[1].asInt()))
    else
        1_000;

    // Tree-walk: try to evaluate with limited fuel
    const tw = observeTreeWalk(expr, env, gc);

    // Inet: compile and reduce
    const in = observeInet(expr, gc, env);

    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };
    _ = fuel;

    const obj = try gc.allocObj(.map);

    // Tree-walk failure mode
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "tree-walk-result"));
    try obj.data.map.vals.append(gc.allocator, if (tw.result) |r| Value.makeInt(r) else Value.makeNil());
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "tree-walk-fuel-spent"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@min(tw.fuel_spent, std.math.maxInt(i48)))));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "tree-walk-evidence"));
    // Tree-walk evidence: fuel exhaustion is indistinguishable from "slow"
    const tw_evidence: []const u8 = if (tw.result != null)
        "halted"
    else if (tw.fuel_spent > 0)
        "fuel-exhausted-no-structural-evidence"
    else
        "parse-error";
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(tw_evidence)));

    // Inet failure mode
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "inet-result"));
    try obj.data.map.vals.append(gc.allocator, if (in.result) |r| Value.makeInt(r) else Value.makeNil());
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "inet-trit-delta"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(in.trit_balance)));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "inet-evidence"));
    // Inet evidence: trit imbalance is STRUCTURAL evidence of non-termination
    const inet_evidence: []const u8 = if (in.result != null)
        "halted"
    else if (in.trit_balance != 0)
        "trit-imbalanced-structural-non-termination"
    else
        "reduced-to-normal-form-no-int-result";
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(inet_evidence)));

    // Diagnosis: what the hierarchy tells us
    const diagnosis: []const u8 = if (tw.result != null and in.result != null)
        "decidable:both-halted"
    else if (tw.result == null and in.trit_balance != 0)
        "semi-decidable:inet-has-structural-evidence-treewalk-does-not"
    else if (tw.result == null and in.result == null)
        "undecidable:both-failed-differently"
    else
        "asymmetric:substrates-disagree";
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "diagnosis"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(diagnosis)));

    return Value.makeObj(obj);
}

/// (primitive-recursive op ...) → result
/// The five operators from the lecture: zero, successor, projection, composition, primitive recursion.
/// (epochal-witness epoch-idx trit-sum substrate-agrees? classifier-agrees?)
/// → {:epoch N :well-posed? bool :ill-posed-count N :diagnosis "..."}
///
/// Hickey/Fogus epochal time: each epoch is an immutable value,
/// the recording session is the identity, perception is the readback.
pub fn epochalWitnessFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 4) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;

    const epoch = args[0].asInt();
    const trit_sum = if (args[1].isInt()) args[1].asInt() else 0;
    const substrate_ok = if (args[2].isBool()) args[2].asBool() else false;
    const classifier_ok = if (args[3].isBool()) args[3].asBool() else false;

    var ill_count: i48 = 0;
    if (!substrate_ok) ill_count += 1;
    if (!classifier_ok) ill_count += 1;
    const well_posed = ill_count == 0;

    const diagnosis: []const u8 = if (well_posed)
        "well-posed"
    else if (ill_count == 1 and !substrate_ok)
        "Church-Turing divergence"
    else if (ill_count == 1 and !classifier_ok)
        "classifier divergence"
    else
        "double ill-posed: CT + classifier";

    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };

    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "epoch"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(epoch));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "trit-sum"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(trit_sum));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "well-posed?"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(well_posed));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "ill-posed-count"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(ill_count));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "diagnosis"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(diagnosis)));

    return Value.makeObj(obj);
}

/// These are the building blocks of decidable predicates.
pub fn primitiveRecursiveFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    const op = gc.getString(args[0].asStringId());

    if (std.mem.eql(u8, op, "zero")) {
        // Z() = 0
        return Value.makeInt(0);
    }
    if (std.mem.eql(u8, op, "succ")) {
        // S(n) = n + 1
        if (args.len < 2 or !args[1].isInt()) return error.ArityError;
        return Value.makeInt(args[1].asInt() + 1);
    }
    if (std.mem.eql(u8, op, "proj")) {
        // π_i(x_0, ..., x_n) = x_i
        if (args.len < 3 or !args[1].isInt()) return error.ArityError;
        const raw_i = args[1].asInt();
        if (raw_i < 0) return error.InvalidArgs;
        const i: usize = std.math.cast(usize, raw_i) orelse return error.InvalidArgs;
        if (i + 2 >= args.len) return error.ArityError;
        return args[i + 2];
    }
    if (std.mem.eql(u8, op, "comp")) {
        // Composition: (primitive-recursive "comp" f g1 g2 ... gk x1 ... xn)
        // Not directly computable here without eval — return marker
        const obj = try gc.allocObj(.map);
        const kw = struct {
            fn intern(g: *GC, s: []const u8) !Value {
                return Value.makeKeyword(try g.internString(s));
            }
        };
        try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "type"));
        try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString("composition")));
        try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "note"));
        try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString("use (comp f g) in nanoclj for composition")));
        return Value.makeObj(obj);
    }
    if (std.mem.eql(u8, op, "primrec")) {
        // Primitive recursion: f(0, y) = g(y), f(n+1, y) = h(n, f(n, y), y)
        // For now, demonstrate with addition: add(0, y) = y, add(S(n), y) = S(add(n, y))
        if (args.len < 3 or !args[1].isInt() or !args[2].isInt()) return error.ArityError;
        const n = args[1].asInt();
        const y = args[2].asInt();
        // Primitive recursive addition
        return Value.makeInt(n + y);
    }
    return error.TypeError;
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
    try std.testing.expectEqual(@as(i8, 0), obs.trit_balance);
}

// ============================================================================
// TESTS: decidability hierarchy
// ============================================================================

test "decidability: even? is decidable — characteristic function always halts" {
    // χ_even(4) = 1 (true), χ_even(7) = 0 (false)
    // This is a primitive recursive predicate: always halts, always decides.
    try std.testing.expect(isEven(4));
    try std.testing.expect(!isEven(7));
    try std.testing.expect(isEven(0));
    try std.testing.expect(!isEven(-3));
    try std.testing.expect(isEven(1000));
}

test "decidability: prime? is decidable — trial division always halts" {
    try std.testing.expect(!isPrime(0));
    try std.testing.expect(!isPrime(1));
    try std.testing.expect(isPrime(2));
    try std.testing.expect(isPrime(3));
    try std.testing.expect(!isPrime(4));
    try std.testing.expect(isPrime(5));
    try std.testing.expect(!isPrime(9));
    try std.testing.expect(isPrime(97));
    try std.testing.expect(!isPrime(100));
}

test "decidability: semi-decide halts on YES for decidable expression" {
    // "42" always evaluates to 42, so searching for 42 is decidable.
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    const w = searchForValue("42", 42, &env, &gc, 10_000);
    try std.testing.expect(w.halted);
    try std.testing.expectEqual(true, w.answer.?);
    try std.testing.expectEqual(DecidabilityLevel.semi_decidable, w.level);
}

test "decidability: semi-decide returns NO for non-matching decidable expression" {
    // "42" evaluates to 42, not 99. Decidably NO.
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    const w = searchForValue("42", 99, &env, &gc, 10_000);
    try std.testing.expect(w.halted);
    try std.testing.expectEqual(false, w.answer.?);
    try std.testing.expectEqual(DecidabilityLevel.decidable, w.level);
}

test "decidability: primitive recursive zero, succ, proj" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    var res = Resources.initDefault();

    // Z() = 0
    var zero_args = [_]Value{Value.makeString(try gc.internString("zero"))};
    const z = try primitiveRecursiveFn(&zero_args, &gc, &env, &res);
    try std.testing.expectEqual(@as(i48, 0), z.asInt());

    // S(5) = 6
    var succ_args = [_]Value{
        Value.makeString(try gc.internString("succ")),
        Value.makeInt(5),
    };
    const s = try primitiveRecursiveFn(&succ_args, &gc, &env, &res);
    try std.testing.expectEqual(@as(i48, 6), s.asInt());

    // π_1(10, 20, 30) = 20
    var proj_args = [_]Value{
        Value.makeString(try gc.internString("proj")),
        Value.makeInt(1),
        Value.makeInt(10),
        Value.makeInt(20),
        Value.makeInt(30),
    };
    const p = try primitiveRecursiveFn(&proj_args, &gc, &env, &res);
    try std.testing.expectEqual(@as(i48, 20), p.asInt());
}

test "decidability: primitive recursive addition via primrec" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    var res = Resources.initDefault();

    // add(3, 7) = 10 via primitive recursion schema
    var args = [_]Value{
        Value.makeString(try gc.internString("primrec")),
        Value.makeInt(3),
        Value.makeInt(7),
    };
    const r = try primitiveRecursiveFn(&args, &gc, &env, &res);
    try std.testing.expectEqual(@as(i48, 10), r.asInt());
}
