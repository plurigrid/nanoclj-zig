//! Defensive Adversarial Interpreter Semantics for nanoclj-zig
//!
//! Decomposed into three interlocking layers:
//!   transclusion.zig  — Domain type, denotational meaning ⟦·⟧, reader bounds
//!   transduction.zig  — Fuel-bounded operational eval (signal transformation)
//!   transitivity.zig  — Structural equality, resource limits, GF(3), soundness
//!
//! This file re-exports everything for backward compatibility.

pub const transclusion = @import("transclusion.zig");
pub const transduction = @import("transduction.zig");
pub const transitivity = @import("transitivity.zig");

// Re-export all public types and functions
pub const Domain = transclusion.Domain;
pub const Adversarial = transclusion.Adversarial;
pub const boundedRead = transclusion.boundedRead;
pub const denote = transclusion.denote;

pub const evalBounded = transduction.evalBounded;

pub const Limits = transitivity.Limits;
pub const Resources = transitivity.Resources;
pub const structuralEq = transitivity.structuralEq;
pub const valueTrit = transitivity.valueTrit;
pub const checkSoundness = transitivity.checkSoundness;

test {
    _ = transclusion;
    _ = transduction;
    _ = transitivity;
}
