# Gas-Fueled Languages and Compiler Correctness

**Source**: Zhirkov, rubber-duck-typing blog
**URL**: https://rubber-duck-typing.com/posts/2025-01-10-gas-fueled-languages.html

## Relevance to nanoclj-zig

Direct parallel to `Resources.tick()` in `transduction.zig`. Gas/fuel metering as first-class language feature.

### Key Points

1. **Gas semantics must be part of the formal semantics** — not bolted on. The compiler must preserve gas consumption across optimizations.
2. **Compiler correctness for gas**: if source program costs G gas, compiled program must cost exactly G gas (not "at most G").
3. **Constant-time gas**: each operation has a fixed gas cost known at compile time. This is what nanoclj-zig currently does with `tick()`.
4. **Proportional gas**: cost proportional to input size. Needed for collection operations.
5. **The optimization problem**: dead code elimination saves gas → but changes observable behavior if gas is observable. Must choose: gas-preserving or gas-reducing optimizations.

### Connection to interaction nets

Interaction net rewrite rules have **exact** cost:
- Annihilation: 2 cells consumed, cost = 2·kT·ln(2)
- Commutation: 4 cells produced from 2, cost = 0 (reversible)
- Erasure: 1 cell consumed, cost = kT·ln(2)

This gives a thermodynamically grounded gas model where compiler correctness = thermodynamic conservation.

### For nanoclj-zig Level 1 (fuel fork/join)

When forking fuel across parallel arg evaluations:
- Total fuel consumed must equal sequential fuel consumed (conservation)
- Fork overhead = 0 (adiabatic, like commutation)
- Join overhead = kT·ln(n) to merge n results (Landauer cost of selecting one outcome)
