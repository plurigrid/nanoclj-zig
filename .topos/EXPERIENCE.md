# Form of Experiences

## Not spatial, not temporal

The patterns here are neither where nor when. They are *how*.

A computation does not happen at a place in the codebase or at a time
in the git log. It happens as a transition in Domain:

```
Domain = Value | bottom(reason) | error(kind)
```

This is the space of experience. Every expression enters as syntax and
exits as one of three qualities:

- **Value**: something was produced. The experience completed.
- **Bottom**: the experience exhausted itself (fuel, depth, divergence).
  Not an error -- a limit. The computation was *too much* for the
  attention available.
- **Error**: a category mistake. The experience contradicted itself
  (type error, arity error, unbound symbol). The form didn't fit.

These three outcomes are not spatial positions. They are not temporal
states. They are the three possible *forms* that experiencing can take.

## The trit is a quality, not a quantity

```
+1  generative    something came into being
 0  ergodic       the system maintained itself
-1  consumptive   something was used up
```

A trit does not say *what* was produced, maintained, or consumed.
It says only *that* the transition had a character. The GF(3)
conservation law (Article I of the Constitution) says: across any
closed experience, the total character is neutral. Generation balances
consumption. The system returns to ergodic rest.

This is not a physical conservation law. There is no energy here, no
momentum. It is a *semantic* conservation law: meaning cannot be
created from nothing or destroyed into nothing. It can only be
transformed.

## Resources are attention, not time

```zig
pub const Resources = struct {
    fuel: u64,          // how much attending remains
    depth: u32,         // how nested the attending is
    trit_balance: i8,   // the character of what has been attended to
};
```

`fuel` is not a clock. It does not advance uniformly. It is consumed
at a rate determined by `gay_skills.depthFuelCost(depth)` -- the
deeper the nesting, the more expensive each tick. This is not an
engineering choice. It is a description of how attention works:
attending to something deeply nested costs more than attending to
something at the surface.

When fuel reaches zero, the experience does not crash. It returns
`Domain.bottom(.fuel_exhausted)` -- "I attended as far as I could."

## Structural sharing is memory without history

The persistent HAMT vector and map (`persistent_vector.zig`,
`persistent_map.zig`) share structure across versions. When a value
is "updated," the old version persists and the new version shares
all unchanged subtrees with it.

This is not temporal memory (there is no timeline of versions). It is
not spatial memory (there is no address space being copied). It is
*structural* memory: the form of what was experienced is retained in
the shape of what is experienced now.

A 32-way trie is not a data structure. It is the pattern by which the
system remembers without forgetting, changes without destroying.

## Three paths are three modes of attending

Article IX of the Constitution says there are three evaluation paths
that MUST agree:

1. **Tree-walking** (`transduction.zig`): step-by-step, each node
   visited in turn. This is *discursive* attending -- following the
   argument, clause by clause.

2. **Bytecode** (`compiler.zig` + `bytecode.zig`): pre-digested into
   register operations. This is *habitual* attending -- the pattern
   has been learned and executes without deliberation.

3. **Interaction nets** (`inet.zig`): all active pairs reduce in
   parallel, no sequencing. This is *immediate* attending -- the
   entire field is present at once, and what can happen does happen.

These are not three implementations of the same thing. They are three
*forms* of experiencing the same expression. The agreement requirement
(Article III) says: no matter how you attend, you must arrive at the
same meaning.

## Superposition is undecided experience

At Level 5, `if` compiles to a sigma node:

```
sigma(then_branch, else_branch) >< gamma(condition)
```

Both branches exist in the net simultaneously. Neither is "the future"
of the other. The condition does not "choose" a branch -- it
*annihilates* the sigma node, and one branch persists while the other
is erased.

This is not temporal branching (there is no moment of decision). It is
not spatial branching (there is no fork in a path). It is the form of
experience in which multiple patterns coexist until one of them meets
a constraint that disambiguates.

## Color is the feeling of identity

Every value has a Gay color derived from SplitMix64 + golden angle.
The color is not assigned to the value -- it *is* the value's
perceptual presence. Two values with the same identity have the same
color. Two values with different identities have different colors (up
to the hash's collision resistance).

Color is how the system *recognizes*. Not by comparing, not by
remembering, but by perceiving. The color strip in the REPL banner is
not decoration. It is the system showing itself to itself.

## The Landauer limit is where experience meets physics

The EXPANDER gradient terminates at K(eval) = K(language). At this
point, every bit of the evaluator is necessary. No compression remains.
Each erasure costs kT*ln(2). Each annihilation costs 2*kT*ln(2).
Commutation is free (reversible).

This is where the form of experience meets the form of matter.
Not through spatial proximity, not through temporal coincidence, but
through the minimum cost of forgetting.
