//! Compatibility shim: behavioral lattice now lives under plural.zig.
//! Keep this file so older imports continue to resolve while the public
//! operational vocabulary moves from "behavior lattice" to "plural".

const plural = @import("plural.zig");

pub const BehaviorLevel = plural.BehaviorLevel;
pub const Feature = plural.Feature;
pub const all_features = plural.all_features;
pub const RuntimeKind = plural.RuntimeKind;
pub const MorphismKind = plural.MorphismKind;
pub const Morphism = plural.Morphism;
pub const EvaluatorProfile = plural.EvaluatorProfile;
pub const RuntimeOrdering = plural.RuntimeOrdering;
pub const ProfileComparison = plural.ProfileComparison;

pub const parseRuntime = plural.parseRuntime;
pub const level = plural.level;
pub const morphism = plural.morphism;
pub const compareProfilesOnExpr = plural.compareProfilesOnExpr;
pub const compareProfileFn = plural.compareProfileFn;
pub const behaviorLatticeFn = plural.behaviorLatticeFn;
pub const behavioralEquivalenceFn = plural.behavioralEquivalenceFn;
pub const behavioralDominanceFn = plural.behavioralDominanceFn;
pub const behaviorCompareFn = plural.behaviorCompareFn;
pub const behaviorProfileFn = plural.behaviorProfileFn;
