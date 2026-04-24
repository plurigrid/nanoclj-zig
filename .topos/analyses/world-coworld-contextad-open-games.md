# World/coworld contextad open games for nanoclj-zig

This note packages the current open-game engine direction for
`nanoclj-zig` into a native `.topos` artifact. It pulls together the
shared monoidal kernel, the contextad layer, and one local modification:
we treat `world` and `coworld` as the pair that closes the semantic
surface of a game. The result is a reproducible design seed anchored at
`seed=42`.

## Goal

The goal is not to add another disconnected DSL. The goal is to make the
open-game story legible inside the substrate that already exists in this
repository.

- `src/monoidal_diagram.zig` gives us a shared diagram IR.
- `src/inet.zig` gives us maximally parallel local rewriting.
- `src/thread_peval.zig` gives us real OS-thread fanout.
- `src/transitivity.zig` gives us fuel, GF(3), and per-run truth mode.
- `src/pluralism.zig` already gives us a first-class `World` record.

That means the missing step is not "invent a universe." The missing step
is to say how an open game inhabits this one.

## World and coworld

In this repository, we can use `world` and `coworld` as a conservative
extension of the usual open-game split between play and coplay.

- `world` is the forward-facing side. It carries observation, action,
  state exposure, and the evolving public face of the game.
- `coworld` is the backward-facing side. It carries payoff, blame,
  explanation, repair obligations, and the private or counterfactual
  account of what a move means.

This is a local design choice, not a claim about the standard
terminology. The point is to make the backward half of the game explicit
enough that the system can reason about its own consequences instead of
treating them as external commentary.

## Contextads in this setting

Contextads enter as the ambient layer around the game, not as another
node kind. A contexted game does not only consume `X` and produce `Y`.
It also runs under a structured context `C`.

- `C_market` carries prices, liquidity, and regime.
- `C_chain` carries AIP or protocol settings.
- `C_governance` carries phase, lock state, and thresholds.
- `C_agent` carries holdings, permissions, and coalition state.
- `C_disclosure` carries whether a flaw is private, staged, or public.

The practical effect is that read-only context can be broadcast across
workers, local context can stay shard-local, and only contended state
needs transactional scheduling.

## Semantically closed AGI world model

For this design, "semantically closed" means the engine does not rely on
an implicit outside observer to finish the meaning of a run. A run is
closed when all of the following hold.

1. Every forward move in `world` has an explicit backward interpretation
   in `coworld`.
2. Every ambient dependency is carried in context rather than smuggled in
   as a hidden global.
3. Every mutation is classified as `readonly`, `local`, or `contended`.
4. Every execution trace can be re-run from `(game, context, seed)`.
5. Every portfolio semantics must agree on externally visible outcomes,
   or else produce a counterexample trace.

This is the reason to keep `world` and `coworld` separate. Closure comes
from pairing them, not collapsing them.

## Seed 42 profile

`seed=42` is the stable reference seed for the first closed profile. The
seed does not change the economics. It only fixes the interpreter choice
inside the semantic portfolio.

- Primary semantics: `inet-batch`
- Companion portfolio: `thread-peval`, `kanren-search`,
  `propagator-fixpoint`
- Companion choice for `seed=42`: `thread-peval`
- Agreement policy: required

Using a fixed seed gives us a golden trace for benchmarks, regression
tests, and future proof obligations.

## Artifact bundle

This note is the prose layer of a three-part `.topos` bundle.

- `models/world-coworld-open-game-seed42.json` is the machine-readable
  profile.
- `diagrams/world-coworld-open-game-seed42.clj` is the concrete lowering
  into the monoidal kernel.
- This analysis explains why those two artifacts are shaped the way they
  are.

## Next steps

The next implementation step is to make this bundle executable rather
than merely descriptive.

1. Extend the diagram kernel with explicit forward and backward ports.
2. Add a `Ctx(OpenGame)` IR layer with `:readonly`, `:local`, and
   `:contended` effect classes.
3. Add `play` and `evaluate` builtins that run the seeded portfolio.
4. Use the `seed=42` profile as the first golden benchmark for Nouns,
   PartyBid, Juicebox, and the Aptos L&T mechanism.
