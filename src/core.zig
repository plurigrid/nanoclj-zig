const std = @import("std");
const compat = @import("compat.zig");
const value = @import("value.zig");
const Value = value.Value;
const ObjKind = value.ObjKind;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const reader_mod = @import("reader.zig");
const printer = @import("printer.zig");
const eval_mod = @import("eval.zig");
const semantics = @import("semantics.zig");
const substrate = @import("substrate.zig");
const gay_skills = @import("gay_skills.zig");
const tree_vfs = @import("tree_vfs.zig");
const inet_builtins = @import("inet_builtins.zig");
const inet_compile = @import("inet_compile.zig");
const http_fetch = @import("http_fetch.zig");
const peval_mod = @import("peval.zig");
const ibc_denom = @import("ibc_denom.zig");
const church_turing = @import("church_turing.zig");
const kanren = @import("kanren.zig");
const regex = @import("regex.zig");
const pluralism = @import("pluralism.zig");
const gorj_bridge = @import("gorj_bridge.zig");
const computable_sets = @import("computable_sets.zig");
const avalon_api_example = @import("avalon_api_example.zig");
const simd_str = @import("simd_str.zig");
const transcendental = @import("transcendental.zig");
const ergodic_bridge = @import("ergodic_bridge.zig");
const concept_tensor = @import("concept_tensor.zig");
const chromatic_propagator = @import("chromatic_propagator.zig");
const gaymc = @import("gaymc.zig");
const hyperdoctrine = @import("hyperdoctrine.zig");
const tower = @import("tower.zig");
const marsaglia_bumpus = @import("marsaglia_bumpus.zig");
const scoped_propagators = @import("scoped_propagators.zig");
const skill_inet = @import("skill_inet.zig");
const decomp = @import("decomp.zig");
const brainfloj = @import("brainfloj.zig");
const congrunet = @import("congrunet.zig");
const holy = @import("holy.zig");
const zipf = @import("zipf.zig");
const channel = @import("channel.zig");
const srcloc = @import("srcloc.zig");

fn getSeedMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC_RAW, &ts);
    return @as(i64, ts.sec) *% 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

pub const BuiltinFn = *const fn (args: []Value, gc: *GC, env: *Env) anyerror!Value;

// We store builtins as a separate lookup rather than in NaN-boxed values.
// The env holds a symbol that maps to a sentinel; we intercept in apply.

var builtin_table: std.StringHashMap(BuiltinFn) = undefined;
var initialized = false;

pub fn initCore(env: *Env, gc: *GC) !void {
    if (!initialized) {
        builtin_table = std.StringHashMap(BuiltinFn).init(gc.allocator);
        initialized = true;
    }

    const builtins = .{
        .{ "+", &add },         .{ "-", &sub },
        .{ "*", &mul },         .{ "/", &div_fn },
        .{ "=", &eql },        .{ "<", &lt },
        .{ ">", &gt },         .{ "<=", &lte },
        .{ ">=", &gte },       .{ "list", &listFn },
        .{ "vector", &vectorFn }, .{ "hash-map", &hashMapFn },
        .{ "first", &first },  .{ "rest", &rest },
        .{ "cons", &cons },    .{ "count", &count },
        .{ "nth", &nth },      .{ "get", &getFn },
        .{ "assoc", &assoc },  .{ "conj", &conj },
        .{ "nil?", &isNilP },  .{ "number?", &isNumberP },
        .{ "string?", &isStringP }, .{ "keyword?", &isKeywordP },
        .{ "symbol?", &isSymbolP }, .{ "list?", &isListP },
        .{ "vector?", &isVectorP }, .{ "map?", &isMapP },
        .{ "fn?", &isFnP },    .{ "println", &printlnFn },
        .{ "pr-str", &prStrFn }, .{ "read-string", &readStringFn }, .{ "load-file", &loadFileFn },
        .{ "str", &strFn },    .{ "subs", &subsFn },
        .{ "split", &splitFn }, .{ "join", &joinFn },
        .{ "replace", &replaceFn }, .{ "index-of", &indexOfFn },
        .{ "starts-with?", &startsWithFn }, .{ "ends-with?", &endsWithFn },
        .{ "trim", &trimFn },
        .{ "upper-case", &upperCaseFn }, .{ "lower-case", &lowerCaseFn },
        .{ "char-at", &charAtFn }, .{ "string-length", &stringLengthFn },
        .{ "not", &notFn },    .{ "mod", &modFn },
        .{ "inc", &incFn },    .{ "dec", &decFn },
        .{ "zero?", &isZeroP },
        .{ "apply", &applyFn },
        .{ "take", &takeFn },
        .{ "drop", &dropFn },
        .{ "reduce", &reduceFn },
        .{ "range", &rangeFn },
        .{ "map", &mapFn },
        .{ "filter", &filterFn },
        .{ "concat", &concatFn },
        .{ "reverse", &reverseFn },
        .{ "empty?", &isEmptyP },
        .{ "into", &intoFn },
        .{ "set?", &isSetP },
        .{ "seq?", &isSeqP },
        .{ "sequential?", &isSequentialP },
        // Trit-tick time quantum builtins
        .{ "trit-phase", &tritPhaseFn },
        .{ "frames->trit-ticks", &framesToTritTicksFn },
        .{ "samples->trit-ticks", &samplesToTritTicksFn },
        .{ "trit-ticks-per-sec", &tritTicksPerSecFn },
        .{ "flicks-per-sec", &flicksPerSecFn },
        .{ "glimpses-per-tick", &glimpsesPerTickFn },
        .{ "cognitive-jerk", &cognitiveJerkFn },
        .{ "p-adic", &padicFn },
        .{ "p-adic-depth", &padicDepthFn },
        // Information spacetime builtins
        .{ "separation", &separationFn },
        .{ "cone-volume", &coneVolumeFn },
        .{ "info-density", &infoDensityFn },
        .{ "causal-depth", &causalDepthFn },
        .{ "padic-cones", &padicConesFn },
        // Jepsen builtins
        .{ "jepsen/nemesis!", &jepsenNemesisFn },
        .{ "jepsen/gen", &jepsenGenFn },
        .{ "jepsen/record!", &jepsenRecordFn },
        .{ "jepsen/check", &jepsenCheckFn },
        .{ "jepsen/reset!", &jepsenResetFn },
        .{ "jepsen/history", &jepsenHistoryFn },
        .{ "jepsen/check-unique-ids", &jepsenCheckUniqueIdsFn },
        .{ "jepsen/check-counter", &jepsenCheckCounterFn },
        .{ "jepsen/check-cas-register", &jepsenCheckCasRegisterFn },
        // Gay Color builtins
        .{ "color-at", &substrate.colorAtFn },
        .{ "color-seed", &substrate.colorSeedFn },
        .{ "colors", &substrate.colorsFn },
        .{ "hue-to-trit", &substrate.hueToTritFn },
        .{ "mix64", &substrate.mix64Fn },
        .{ "xor-fingerprint", &substrate.xorFingerprintFn },
        // Universal index-addressed primitive
        .{ "at", &atFn },
        .{ "trit-at", &tritAtFn },
        .{ "trit-sum", &tritSumFn },
        .{ "find-balancer", &findBalancerFn },
        .{ "trit-of", &tritOfContentFn },
        // Pattern matching: 6 engines (3 regexp + 3 PEG)
        .{ "re-match", &reMatchFn },
        .{ "peg-match", &pegMatchFn },
        .{ "match-all", &matchAllFn },
        // Splittable RNG builtins
        .{ "split-rng", &splitRngFn },
        .{ "rng-next", &rngNextFn },
        .{ "rng-split", &rngSplitFn },
        .{ "rng-trit", &rngTritFn },
        // GF(3) builtins
        .{ "gf3-add", &substrate.gf3AddFn },
        .{ "gf3-mul", &substrate.gf3MulFn },
        .{ "gf3-conserved?", &substrate.gf3ConservedFn },
        .{ "trit-balance", &substrate.tritBalanceFn },
        // BCI builtins
        .{ "bci-channels", &substrate.bciChannelsFn },
        .{ "bci-read", &substrate.bciReadFn },
        .{ "bci-trit", &substrate.bciTritFn },
        .{ "bci-entropy", &substrate.bciEntropyFn },
        // Brainfloj builtins
        .{ "brainfloj-parse", &brainfloj.brainflojParseFn },
        .{ "brainfloj-read", &brainfloj.brainflojReadFn },
        // HolyZig builtins
        .{ "holy-eval", &holy.holyEvalFn },
        .{ "holy-converge", &holy.holyConvergeFn },
        .{ "holy-converge-trace", &holy.holyConvergeTraceFn },
        .{ "holy-converge-summary", &holy.holyConvergeSummaryFn },
        .{ "congrunet-summary", &congrunet.congrunetSummaryFn },
        .{ "congrunet-trace", &congrunet.congrunetTraceFn },
        .{ "congrunet-presheaf", &congrunet.congrunetPresheafFn },
        // nREPL
        .{ "nrepl-start", &substrate.nreplStartFn },
        // Substrate traversal
        .{ "substrate", &substrate.substrateFn },
        .{ "traverse", &substrate.traverseFn },
        // Gay Skills 3,4,9-13,15-17 (1-2,5-8,14 already above)
        .{ "color-hex", &gay_skills.colorHexFn },
        .{ "color-trit", &gay_skills.colorTritFn },
        .{ "tropical-add", &gay_skills.tropicalAddFn },
        .{ "tropical-mul", &gay_skills.tropicalMulFn },
        .{ "world-create", &gay_skills.worldCreateFn },
        .{ "world-step", &gay_skills.worldStepFn },
        .{ "propagate", &gay_skills.propagateFn },
        .{ "entropy", &gay_skills.entropyFn },
        .{ "depth-color", &gay_skills.depthColorFn },
        .{ "bisim?", &gay_skills.bisimCheckFn },
        // Tree VFS builtins (horse/ Forester forest)
        .{ "tree-read", &tree_vfs.treeReadFn },
        .{ "tree-title", &tree_vfs.treeTitleFn },
        .{ "tree-transcluded", &tree_vfs.treeTranscludedFn },
        .{ "tree-transcluders", &tree_vfs.treeTranscludersFn },
        .{ "tree-ids", &tree_vfs.treeIdsFn },
        .{ "tree-isolated", &tree_vfs.treeIsolatedFn },
        .{ "tree-chain", &tree_vfs.treeChainFn },
        .{ "tree-taxon", &tree_vfs.treeTaxonFn },
        .{ "tree-author", &tree_vfs.treeAuthorFn },
        .{ "tree-meta", &tree_vfs.treeMetaFn },
        .{ "tree-imports", &tree_vfs.treeImportsFn },
        .{ "tree-by-taxon", &tree_vfs.treeByTaxonFn },
        // Interaction net builtins
        .{ "inet-new", &inet_builtins.inetNewFn },
        .{ "inet-cell", &inet_builtins.inetCellFn },
        .{ "inet-wire", &inet_builtins.inetWireFn },
        .{ "inet-reduce", &inet_builtins.inetReduceFn },
        .{ "inet-live", &inet_builtins.inetLiveFn },
        .{ "inet-pairs", &inet_builtins.inetPairsFn },
        .{ "inet-trit", &inet_builtins.inetTritFn },
        .{ "inet-from-forest", &inet_builtins.inetFromForestFn },
        .{ "inet-dot", &inet_builtins.inetDotFn },
        .{ "inet-compile", &inet_compile.inetCompileFn },
        .{ "inet-readback", &inet_compile.inetReadbackFn },
        .{ "inet-eval", &inet_compile.inetEvalFn },
        // Partial evaluation (first Futamura projection)
        .{ "peval", &peval_mod.pevalFn },
        // HTTP fetch
        .{ "http-fetch", &http_fetch.httpFetchFn },
        // IBC denom (bmorphism/shitcoin geodesic)
        .{ "ibc-denom", &ibc_denom.ibcDenomFn },
        .{ "ibc-trit", &ibc_denom.ibcTritFn },
        .{ "noble-usdc-on", &ibc_denom.nobleUsdcOnFn },
        .{ "noble-precompute", &ibc_denom.noblePrecomputeFn },
        .{ "noble-channels", &ibc_denom.nobleChannelsFn },
        // Church-Turing ill-posedness witness
        .{ "ill-posed", &church_turing.illPosedFn },
        // Decidability hierarchy
        .{ "decidable?", &church_turing.decidableFn },
        .{ "semi-decide", &church_turing.semiDecideFn },
        .{ "halting-witness", &church_turing.haltingWitnessFn },
        .{ "epochal-witness", &church_turing.epochalWitnessFn },
        .{ "primitive-recursive", &church_turing.primitiveRecursiveFn },
        // miniKanren — relational programming (SPJ→Fogus→Hickey)
        .{ "lvar", &kanren.lvarFn },
        .{ "lvar?", &kanren.lvarP },
        .{ "unify", &kanren.unifyFn },
        .{ "walk*", &kanren.walkStarFn },
        .{ "==", &kanren.eqGoalFn },
        .{ "conde", &kanren.condeFn },
        .{ "conj-goal", &kanren.conjGoalFn },
        .{ "fresh-goal", &kanren.freshGoalFn },
        .{ "run-goal", &kanren.runGoalFn },
        .{ "conso", &kanren.consoFn },
        .{ "appendo", &kanren.appendoFn },
        .{ "membero", &kanren.memberoFn },
        .{ "evalo", &kanren.evaloFn },
        .{ "lookupo", &kanren.lookupoFn },
        // gorj bridge — collapsed loops (no hex roundtrip, fused eval pipeline)
        .{ "gorj-pipe", &gorj_bridge.gorjPipeFn },
        .{ "gorj-eval", &gorj_bridge.gorjEvalFn },
        .{ "gorj-encode", &gorj_bridge.gorjEncodeFn },
        .{ "gorj-decode", &gorj_bridge.gorjDecodeFn },
        .{ "gorj-version", &gorj_bridge.gorjVersionFn },
        .{ "gorj-tools", &gorj_bridge.gorjToolsFn },
        // Computable sets, reductions, Weihrauch degrees, guideline auditor
        .{ "computable-set", &computable_sets.computableSetFn },
        .{ "set-density", &computable_sets.setDensityFn },
        .{ "reduce-verify", &computable_sets.reduceVerifyFn },
        .{ "weihrauch-degree", &computable_sets.weihrauchDegreeFn },
        .{ "audit-guideline", &computable_sets.auditGuidelineFn },
        .{ "audit-all-guidelines", &computable_sets.auditAllGuidelinesFn },
        // Arithmetical hierarchy
        .{ "classify-problem", &computable_sets.classifyProblemFn },
        .{ "detect-morphism", &computable_sets.detectMorphismFn },
        .{ "list-problems", &computable_sets.listProblemsFn },
        // Möbius inversion & realizability
        .{ "mobius", &computable_sets.mobiusBuiltinFn },
        .{ "mertens", &computable_sets.mertensBuiltinFn },
        .{ "moebius-boundary", &computable_sets.moebiusBoundaryFn },
        .{ "flip-primes", &computable_sets.flipPrimesFn },
        .{ "morphism-graph", &computable_sets.morphismGraphFn },
        // Gorard ordinal tower
        .{ "gorard-tower", &computable_sets.gorardTowerFn },
        .{ "gorard-trit-sum", &computable_sets.gorardTritSumFn },
        // stopthrowingrocks blog concepts
        .{ "simulation-fuel", &computable_sets.simulationFuelFn },
        .{ "simulation-escape?", &computable_sets.simulationEscapeFn },
        .{ "matrix-derivation", &computable_sets.matrixDerivationFn },
        .{ "matrix-derivation-trace", &computable_sets.matrixDerivationTraceFn },
        .{ "gromov-matrix", &computable_sets.gromovMatrixFn },
        .{ "color-sort-trit-sum", &computable_sets.colorSortTritSumFn },
        .{ "turn-state", &computable_sets.turnStateFn },
        .{ "consensus-classify", &computable_sets.consensusClassifyFn },
        // Stacks Project
        .{ "stacks-tags", &computable_sets.stacksTagsFn },
        .{ "stacks-trit-sum", &computable_sets.stacksTritSumFn },
        .{ "stacks-lookup", &computable_sets.stacksLookupFn },
        // Matter lamp (IKEA VARMBLIXT + BILRESA)
        .{ "matter-lamp", &computable_sets.matterLampFn },
        .{ "bilresa-commands", &computable_sets.bilresaCommandsFn },
        .{ "bilresa-trit-sum", &computable_sets.bilresaTritSumFn },
        .{ "matter-scene", &computable_sets.matterSceneFn },
        // Diophantine equations
        .{ "pythagorean-triples", &computable_sets.pythagoreanTriplesFn },
        .{ "pell-solve", &computable_sets.pellSolveFn },
        .{ "markov-triples", &computable_sets.markovTriplesFn },
        .{ "rh-check", &computable_sets.rhCheckFn },
        // Avalon integration API sample spec
        .{ "avalon-api-spec", &avalon_api_example.avalonApiSpecFn },
        .{ "avalon-api-example", &avalon_api_example.avalonApiExampleFn },
        // Ergodic bridge (Gay.jl ergodic_bridge.jl)
        .{ "wall-clock-bridge", &ergodic_bridge.wallClockBridgeFn },
        .{ "color-bandwidth", &ergodic_bridge.colorBandwidthFn },
        .{ "ergodic-measure", &ergodic_bridge.ergodicMeasureFn },
        .{ "detect-obstructions", &ergodic_bridge.detectObstructionsFn },
        // Concept tensor (Gay.jl concept_tensor.jl)
        .{ "concept-lattice", &concept_tensor.conceptLatticeFn },
        .{ "concept-at", &concept_tensor.conceptAtFn },
        .{ "lattice-magnetization", &concept_tensor.latticeMagnetizationFn },
        .{ "verify-monoid", &concept_tensor.verifyMonoidFn },
        .{ "lattice-step", &concept_tensor.latticeStepFn },
        // Chromatic propagator (Gay.jl chromatic_propagator.jl)
        .{ "chromatic-env", &chromatic_propagator.chromaticEnvFn },
        .{ "chromatic-define", &chromatic_propagator.chromaticDefineFn },
        .{ "chromatic-tell", &chromatic_propagator.chromaticTellFn },
        .{ "chromatic-conservation", &chromatic_propagator.chromaticConservationFn },
        // Colored Monte Carlo (Gay.jl gaymc.jl)
        .{ "mc-context", &gaymc.mcContextFn },
        .{ "mc-sweep", &gaymc.mcSweepFn },
        .{ "mc-metropolis", &gaymc.mcMetropolisFn },
        .{ "mc-ladder", &gaymc.mcLadderFn },
        .{ "mc-replica", &gaymc.mcReplicaFn },
        // Hyperdoctrine (Gay.jl hyperdoctrine.jl)
        .{ "heyting-and", &hyperdoctrine.heytingAndFn },
        .{ "heyting-or", &hyperdoctrine.heytingOrFn },
        .{ "heyting-not", &hyperdoctrine.heytingNotFn },
        .{ "heyting-implies", &hyperdoctrine.heytingImpliesFn },
        .{ "beck-chevalley", &hyperdoctrine.beckChevalleyFn },
        // 12-layer SPI tower (Gay.jl tower.jl)
        .{ "tower-run", &tower.towerRunFn },
        .{ "tower-layer", &tower.towerLayerFn },
        .{ "tower-trit-sum", &tower.towerTritSumFn },
        // Marsaglia-Bumpus SPI audit (Gay.jl marsaglia_bumpus_tests.jl)
        .{ "spi-audit", &marsaglia_bumpus.spiAuditFn },
        .{ "runs-test", &marsaglia_bumpus.runsTestFn },
        .{ "split-tree", &marsaglia_bumpus.splitTreeFn },
        // Scoped propagators (Gay.jl scoped_propagators.jl)
        .{ "ancestry-acset", &scoped_propagators.ancestryAcsetFn },
        .{ "materialize", &scoped_propagators.materializeFn },
        .{ "propagate-strategy", &scoped_propagators.propagateStrategyFn },
        // Core data ops
        .{ "dissoc", &dissocFn },
        .{ "update", &updateFn },
        .{ "merge", &mergeFn },
        .{ "select-keys", &selectKeysFn },
        .{ "keys", &keysFn },
        .{ "vals", &valsFn },
        .{ "contains?", &containsFn },
        // Sequence extras
        .{ "second", &secondFn },
        .{ "last", &lastFn },
        .{ "some", &someFn },
        .{ "every?", &everyFn },
        .{ "not-any?", &notAnyFn },
        .{ "sort", &sortFn },
        .{ "sort-by", &sortByFn },
        .{ "distinct", &distinctFn },
        .{ "flatten", &flattenFn },
        .{ "mapcat", &mapcatFn },
        .{ "interleave", &interleaveFn },
        .{ "interpose", &interposeFn },
        .{ "partition", &partitionFn },
        .{ "frequencies", &frequenciesFn },
        .{ "group-by", &groupByFn },
        // Type ops
        .{ "name", &nameFn },
        .{ "keyword", &keywordFn },
        .{ "symbol", &symbolFn },
        .{ "type", &typeFn },
        .{ "identity", &identityFn },
        // Atom / reference types
        .{ "atom", &atomFn },
        .{ "deref", &derefFn },
        .{ "swap!", &swapFn },
        .{ "reset!", &resetFn },
        .{ "compare-and-set!", &compareAndSetFn },
        // IO
        .{ "slurp", &slurpFn },
        .{ "spit", &spitFn },
        .{ "read-line", &readLineFn },
        .{ "shell", &shellFn },
        .{ "sh", &shellFn },
        // Math extras
        .{ "abs", &absFn },
        .{ "min", &minFn },
        .{ "max", &maxFn },
        .{ "rand", &randFn },
        .{ "rand-int", &randIntFn },
        // Bitwise
        .{ "bit-and", &bitAndFn },
        .{ "bit-or", &bitOrFn },
        .{ "bit-xor", &bitXorFn },
        .{ "bit-shift-left", &bitShiftLeftFn },
        .{ "bit-shift-right", &bitShiftRightFn },
        // String extras (SIMD-backed)
        .{ "re-find", &reFindFn },
        .{ "count-str", &countStrFn },
        // Transcendental idealism (Kantian categories)
        .{ "judge", &transcendental.judgeFn },
        .{ "categories", &transcendental.categoriesFn },
        .{ "antinomy", &transcendental.antinomyFn },
        .{ "phenomenon", &transcendental.phenomenonFn },
        .{ "noumenon", &transcendental.noumenonFn },
        // HOF combinators (using partial_fn ObjKind)
        .{ "partial", &partialFn },
        .{ "comp", &compFn },
        .{ "juxt", &juxtFn },
        .{ "complement", &complementFn },
        .{ "constantly", &constantlyFn },
        // Lazy sequences
        .{ "lazy-seq", &lazySeqFn },
        .{ "iterate", &iterateFn },
        .{ "repeat", &repeatFn },
        .{ "repeatedly", &repeatedlyFn },
        .{ "take-while", &takeWhileFn },
        .{ "drop-while", &dropWhileFn },
        .{ "zipmap", &zipmapFn },
        // Additional predicates
        .{ "realized?", &realizedFn },
        .{ "integer?", &isIntegerP },
        .{ "float?", &isFloatP },
        .{ "pos?", &isPosP },
        .{ "neg?", &isNegP },
        .{ "even?", &isEvenP },
        .{ "odd?", &isOddP },
        // Test framework
        .{ "is", &isFn },
        .{ "is=", &isEqualFn },
        .{ "run-tests", &runTestsFn },
        // Namespace ops
        .{ "*ns*", &currentNsFn },
        .{ "ns-name", &nsNameFn },
        .{ "all-ns", &allNsFn },
        .{ "require", &requireFn },
        // Colorspace ops
        .{ "*cs*", &currentCsFn },
        .{ "cs-color", &csColorFn },
        .{ "cs-complement", &csComplementFn },
        .{ "cs-distance", &csDistanceFn },
        .{ "cs-hue", &csHueFn },
        .{ "cs-chroma", &csChromaFn },
        .{ "cs-resolve", &csResolveFn },
        .{ "cs-radius", &csRadiusFn },
        // First-class color ops
        .{ "color", &colorCtorFn },
        .{ "color?", &colorPredFn },
        .{ "color-blend", &colorBlendFn },
        .{ "color-complement", &colorComplementFn },
        .{ "color-analogous", &colorAnalogousFn },
        .{ "color-triadic", &colorTriadicFn },
        .{ "color-distance", &colorDistanceFn },
        .{ "color-hue", &colorHueFn },
        .{ "color-chroma", &colorChromaFn },
        .{ "color-L", &colorLFn },
        .{ "color-a", &colorAFn },
        .{ "color-b", &colorBFn },
        .{ "color-alpha", &colorAlphaFn },
        // Regex
        .{ "re-pattern", &rePatternFn },
        .{ "re-matches", &reMatchesFn },
        .{ "re-seq", &reSeqFn },
        // Nested map ops
        .{ "get-in", &getInFn },
        .{ "assoc-in", &assocInFn },
        .{ "update-in", &updateInFn },
        .{ "reduce-kv", &reduceKvFn },
        // Transients
        .{ "transient", &transientFn },
        .{ "persistent!", &persistentBangFn },
        .{ "conj!", &conjBangFn },
        .{ "assoc!", &assocBangFn },
        .{ "dissoc!", &dissocBangFn },
        .{ "transient?", &isTransientFn },
        // Core sequence ops
        .{ "seq", &seqFn },
        .{ "vec", &vecFn },
        .{ "next", &nextFn },
        .{ "butlast", &butlastFn },
        .{ "ffirst", &ffirstFn },
        .{ "fnext", &fnextFn },
        .{ "peek", &peekFn },
        .{ "pop", &popFn },
        .{ "disj", &disjFn },
        .{ "empty", &emptyFn },
        .{ "not-empty", &notEmptyFn },
        // Math
        .{ "rem", &remFn },
        .{ "quot", &quotFn },
        .{ "hash", &hashFn },
        // Type coercion
        .{ "char", &charFn },
        .{ "int", &intFn },
        .{ "long", &longFn },
        .{ "double", &doubleFn },
        .{ "byte", &byteFn },
        .{ "num", &numFn },
        // Additional predicates
        .{ "true?", &isTrueP },
        .{ "false?", &isFalseP },
        .{ "coll?", &isCollP },
        .{ "boolean?", &isBoolP },
        .{ "char?", &isCharP },
        .{ "int?", &isIntP },
        .{ "identical?", &identicalP },
        .{ "compare", &compareFn },
        .{ "format", &formatFn },
        // Batch 2: predicates + ops for 69% coverage
        .{ "not=", &notEqFn },
        .{ "any?", &anyP },
        .{ "some?", &someP },
        .{ "nan?", &nanP },
        .{ "double?", &isDoubleP },
        .{ "seqable?", &seqableP },
        .{ "counted?", &countedP },
        .{ "associative?", &associativeP },
        .{ "ident?", &identP },
        .{ "ifn?", &ifnP },
        .{ "qualified-ident?", &qualIdentP },
        .{ "qualified-keyword?", &qualKeywordP },
        .{ "qualified-symbol?", &qualSymbolP },
        .{ "simple-ident?", &simpleIdentP },
        .{ "simple-keyword?", &simpleKeywordP },
        .{ "simple-symbol?", &simpleSymbolP },
        .{ "neg-int?", &negIntP },
        .{ "pos-int?", &posIntP },
        .{ "nat-int?", &natIntP },
        .{ "special-symbol?", &specialSymbolP },
        .{ "var?", &varP },
        .{ "ratio?", &ratioP },
        .{ "rational?", &rationalP },
        .{ "decimal?", &decimalP },
        .{ "uuid?", &uuidP },
        .{ "reversible?", &reversibleP },
        .{ "sorted?", &sortedP },
        // Sequence ops
        .{ "nfirst", &nfirstFn },
        .{ "nnext", &nnextFn },
        .{ "nthnext", &nthnextFn },
        .{ "nthrest", &nthrestFn },
        .{ "find", &findFn },
        .{ "key", &keyFn },
        .{ "val", &valFn2 },
        .{ "subvec", &subvecFn },
        .{ "take-last", &takeLastFn },
        .{ "take-nth", &takeNthFn },
        .{ "drop-last", &dropLastFn },
        .{ "cycle", &cycleFn },
        .{ "shuffle", &shuffleFn },
        .{ "rand-nth", &randNthFn },
        .{ "min-key", &minKeyFn },
        .{ "max-key", &maxKeyFn },
        .{ "some-fn", &someFnFn },
        .{ "fnil", &fnilFn },
        .{ "hash-set", &hashSetFn },
        .{ "namespace", &namespaceFn },
        .{ "parse-long", &parseLongFn },
        .{ "parse-double", &parseDoubleFn },
        .{ "parse-boolean", &parseBooleanFn },
        // Bitwise extras
        .{ "bit-not", &bitNotFn },
        .{ "bit-test", &bitTestFn },
        .{ "bit-set", &bitSetFn },
        .{ "bit-clear", &bitClearFn },
        .{ "bit-flip", &bitFlipFn },
        .{ "bit-and-not", &bitAndNotFn },
        .{ "unsigned-bit-shift-right", &unsignedBitShiftRightFn },
        // Metadata
        .{ "meta", &metaFn },
        .{ "with-meta", &withMetaFn },
        .{ "vary-meta", &varyMetaFn },
        // Sequence ops
        .{ "mapv", &mapvFn },
        .{ "filterv", &filtervFn },
        .{ "remove", &removeFn },
        .{ "keep", &keepFn },
        .{ "keep-indexed", &keepIndexedFn },
        .{ "map-indexed", &mapIndexedFn },
        // I/O
        .{ "print", &printFn },
        .{ "pr", &prFn },
        .{ "prn", &prnFn },
        .{ "newline", &newlineFn },
        // Mutable refs
        .{ "volatile!", &volatileBangFn },
        .{ "vswap!", &vswapBangFn },
        .{ "vreset!", &vresetBangFn },
        // Reduce
        .{ "reductions", &reductionsFn },
        .{ "reduced", &reducedFn },
        .{ "reduced?", &isReducedP },
        .{ "unreduced", &unreducedFn },
        .{ "transduce", &transduceFn },
        // Misc
        .{ "delay", &delayFn },
        .{ "force", &forceFn },
        .{ "add-watch", &addWatchFn },
        .{ "remove-watch", &removeWatchFn },
        // Pluralism — oppositional worlding
        .{ "set-world!", &pluralism.setWorldFn },
        .{ "current-world", &pluralism.currentWorldFn },
        .{ "plural-equal?", &pluralism.pluralEqualFn },
        .{ "plural-compare", &pluralism.pluralCompareFn },
        .{ "trit", &pluralism.tritFn },
        .{ "plural-hash", &pluralism.pluralHashFn },
        // Dense f64 (Neanderthal-compatible)
        .{ "fv", &fvFn },
        .{ "fv-get", &fvGetFn },
        .{ "fv-set!", &fvSetBangFn },
        .{ "fv-dot", &fvDotFn },
        .{ "fv-norm", &fvNormFn },
        .{ "fv-axpy!", &fvAxpyBangFn },
        .{ "fv-count", &fvCountFn },
        // Trace (Anglican-compatible)
        .{ "make-trace", &makeTraceFn },
        .{ "trace-observe!", &traceObserveBangFn },
        .{ "trace-log-weight", &traceLogWeightFn },
        .{ "trace-sites", &traceSitesFn },
        // Rational numbers (exact arithmetic)
        .{ "rational", &rationalFn },
        .{ "numerator", &numeratorFn },
        .{ "denominator", &denominatorFn },
        .{ "rationalize", &rationalizeFn },
        .{ "rational?", &isRationalObjP },
        // Skill inet (Agent Skills progressive disclosure via interaction nets)
        .{ "skill-register", &skill_inet.skillRegisterFn },
        .{ "skill-activate", &skill_inet.skillActivateFn },
        .{ "skill-list", &skill_inet.skillListFn },
        .{ "skill-load", &skill_inet.skillLoadFn },
        .{ "skill-parse-file", &skill_inet.skillParseFileFn },
        .{ "skill-net-stats", &skill_inet.skillNetStatsFn },
        .{ "skill-watch", &skill_inet.skillWatchFn },
        .{ "skill-watch-all", &skill_inet.skillWatchAllFn },
        .{ "skill-transclude", &skill_inet.skillTranscludeFn },
        .{ "skill-cache-stats", &skill_inet.skillCacheStatsFn },
        .{ "skill-invalidate", &skill_inet.skillInvalidateFn },
        // Structured decompositions + sheaves
        .{ "decompose", &decomp.decomposeFn },
        .{ "decomp-bags", &decomp.decompBagsFn },
        .{ "decomp-width", &decomp.decompWidthFn },
        .{ "decomp-glue", &decomp.decompGlueFn },
        .{ "decomp-map", &decomp.decompMapFn },
        .{ "decomp-decide", &decomp.decompDecideFn },
        .{ "decomp-skeleton", &decomp.decompSkeletonFn },
        .{ "decomp-adhesions", &decomp.decompAdhesionsFn },
        .{ "sheaf", &decomp.sheafFn },
        .{ "section", &decomp.sectionFn },
        .{ "restrict", &decomp.restrictFn },
        .{ "extend-section", &decomp.extendSectionFn },
        .{ "trit-trajectory", &decomp.tritTrajectoryFn },
        .{ "decomp-gf3", &decomp.decompGf3Fn },
        // Zipf's law — power-law rank-frequency distributions
        .{ "zipf-rank", &zipf.zipfRankFn },
        .{ "zipf-pmf", &zipf.zipfPmfFn },
        .{ "zipf-harmonic", &zipf.zipfHarmonicFn },
        .{ "zipf-top-share", &zipf.zipfTopShareFn },
        .{ "zipf-sample", &zipf.zipfSampleFn },
        .{ "zipf-taper", &zipf.zipfTaperFn },
        .{ "zipf-mandelbrot", &zipf.zipfMandelbrotFn },
        // CSP channels (core.async-style)
        .{ "chan", &channel.chanFn },
        .{ "chan?", &channel.chanPredFn },
        .{ "chan!", &channel.chanPutFn },
        .{ "<!", &channel.chanTakeFn },
        .{ "close!", &channel.chanCloseFn },
        .{ "closed?", &channel.chanClosedPredFn },
        .{ "chan-count", &channel.chanCountFn },
        .{ "offer!", &channel.chanOfferFn },
        .{ "poll!", &channel.chanPollFn },
    };

    inline for (builtins) |b| {
        try builtin_table.put(b[0], b[1]);
        // Put a keyword as sentinel value for the builtin name
        const id = try gc.internString(b[0]);
        try env.set(b[0], Value.makeKeyword(id));
        try env.setById(id, Value.makeKeyword(id));
    }
}

pub fn deinitCore() void {
    if (initialized) {
        builtin_table.deinit();
        initialized = false;
    }
}

pub fn lookupBuiltin(name: []const u8) ?BuiltinFn {
    if (!initialized) return null;
    return builtin_table.get(name);
}

pub fn isBuiltinSentinel(val: Value, gc: *GC) ?[]const u8 {
    if (!val.isKeyword()) return null;
    const name = gc.getString(val.asKeywordId());
    if (lookupBuiltin(name) != null) return name;
    return null;
}

// Arithmetic
fn add(args: []Value, _: *GC, _: *Env) anyerror!Value {
    var sum_i: i48 = 0;
    var sum_f: f64 = 0;
    var is_float = false;
    for (args) |a| {
        if (a.isInt()) {
            sum_i += a.asInt();
            sum_f += @floatFromInt(a.asInt());
        } else {
            is_float = true;
            sum_f += a.asFloat();
        }
    }
    return if (is_float) Value.makeFloat(sum_f) else Value.makeInt(sum_i);
}

fn sub(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    if (args.len == 1) {
        if (args[0].isInt()) return Value.makeInt(-args[0].asInt());
        return Value.makeFloat(-args[0].asFloat());
    }
    var is_float = false;
    var result_i = if (args[0].isInt()) args[0].asInt() else blk: {
        is_float = true;
        break :blk @as(i48, 0);
    };
    var result_f: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    for (args[1..]) |a| {
        if (a.isInt()) {
            result_i -= a.asInt();
            result_f -= @floatFromInt(a.asInt());
        } else {
            is_float = true;
            result_f -= a.asFloat();
        }
    }
    return if (is_float) Value.makeFloat(result_f) else Value.makeInt(result_i);
}

fn mul(args: []Value, _: *GC, _: *Env) anyerror!Value {
    var prod_i: i48 = 1;
    var prod_f: f64 = 1;
    var is_float = false;
    for (args) |a| {
        if (a.isInt()) {
            prod_i *= a.asInt();
            prod_f *= @floatFromInt(a.asInt());
        } else {
            is_float = true;
            prod_f *= a.asFloat();
        }
    }
    return if (is_float) Value.makeFloat(prod_f) else Value.makeInt(prod_i);
}

fn div_fn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    // Integer division when both args are ints and evenly divisible
    if (args[0].isInt() and args[1].isInt()) {
        const b = args[1].asInt();
        if (b == 0) return error.DivisionByZero;
        const a = args[0].asInt();
        if (@rem(a, b) == 0) return Value.makeInt(@divTrunc(a, b));
    }
    const a_f: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    const b_f: f64 = if (args[1].isInt()) @floatFromInt(args[1].asInt()) else args[1].asFloat();
    return Value.makeFloat(a_f / b_f);
}

fn modFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0].isInt() and args[1].isInt()) {
        return Value.makeInt(@rem(args[0].asInt(), args[1].asInt()));
    }
    // Support float mod
    const a_f: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else if (args[0].isFloat()) args[0].asFloat() else return error.TypeError;
    const b_f: f64 = if (args[1].isInt()) @floatFromInt(args[1].asInt()) else if (args[1].isFloat()) args[1].asFloat() else return error.TypeError;
    return Value.makeFloat(@rem(a_f, b_f));
}

// Comparison
fn eql(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return Value.makeBool(semantics.structuralEq(args[0], args[1], gc));
}

fn lt(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return numCmp(args[0], args[1], .lt);
}
fn gt(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return numCmp(args[0], args[1], .gt);
}
fn lte(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return numCmp(args[0], args[1], .lte);
}
fn gte(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return numCmp(args[0], args[1], .gte);
}

const CmpOp = enum { lt, gt, lte, gte };
fn numCmp(a: Value, b: Value, op: CmpOp) anyerror!Value {
    const af: f64 = if (a.isInt()) @floatFromInt(a.asInt()) else a.asFloat();
    const bf: f64 = if (b.isInt()) @floatFromInt(b.asInt()) else b.asFloat();
    const result = switch (op) {
        .lt => af < bf,
        .gt => af > bf,
        .lte => af <= bf,
        .gte => af >= bf,
    };
    return Value.makeBool(result);
}

// Collections
fn listFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const obj = try gc.allocObj(.list);
    for (args) |a| try obj.data.list.items.append(gc.allocator, a);
    return Value.makeObj(obj);
}

fn vectorFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const obj = try gc.allocObj(.vector);
    for (args) |a| try obj.data.vector.items.append(gc.allocator, a);
    return Value.makeObj(obj);
}

fn hashMapFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len % 2 != 0) return error.ArityError;
    const obj = try gc.allocObj(.map);
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        try obj.data.map.keys.append(gc.allocator, args[i]);
        try obj.data.map.vals.append(gc.allocator, args[i + 1]);
    }
    return Value.makeObj(obj);
}

fn first(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil()) return Value.makeNil();
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    // Handle lazy-seq: force the first element only
    if (obj.kind == .lazy_seq) {
        const thunk = obj.data.lazy_seq.thunk;
        if (thunk.isObj() and thunk.asObj().kind == .vector) {
            const payload = thunk.asObj().data.vector.items.items;
            if (payload.len >= 2 and payload[0].isKeyword()) {
                const marker = gc.getString(payload[0].asKeywordId());
                if (std.mem.eql(u8, marker, "__repeat__")) {
                    // (repeat val) or (repeat n val): first element is val
                    const val = if (payload.len >= 3) payload[2] else payload[1];
                    // Check finite repeat with 0 count
                    if (payload.len >= 3 and payload[1].isInt() and payload[1].asInt() <= 0) return Value.makeNil();
                    return val;
                }
                if (std.mem.eql(u8, marker, "__iterate__")) {
                    // (iterate f init): first element is init
                    return payload[2];
                }
                if (std.mem.eql(u8, marker, "__repeatedly__")) {
                    // (repeatedly f): call f once
                    const f = payload[1];
                    return eval_mod.apply(f, &.{}, env, gc) catch Value.makeNil();
                }
                if (std.mem.eql(u8, marker, "__range__")) {
                    // (range): first element is start
                    return payload[1];
                }
            }
        }
        // Generic lazy-seq: call thunk and get first of result
        if (!thunk.isNil()) {
            const realized = eval_mod.apply(thunk, &.{}, env, gc) catch return Value.makeNil();
            if (realized.isObj()) {
                const ritems = getItems(realized) orelse return Value.makeNil();
                return if (ritems.len > 0) ritems[0] else Value.makeNil();
            }
            // If thunk returned a non-collection value, return it directly
            if (!realized.isNil()) return realized;
        }
        return Value.makeNil();
    }
    const items = switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        else => return error.TypeError,
    };
    return if (items.len > 0) items[0] else Value.makeNil();
}

fn rest(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const new = try gc.allocObj(.list);
    if (args[0].isNil()) return Value.makeObj(new);
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    // Handle lazy-seq: return a new lazy_seq representing the rest
    if (obj.kind == .lazy_seq) {
        const thunk = obj.data.lazy_seq.thunk;
        if (thunk.isObj() and thunk.asObj().kind == .vector) {
            const payload = thunk.asObj().data.vector.items.items;
            if (payload.len >= 2 and payload[0].isKeyword()) {
                const marker = gc.getString(payload[0].asKeywordId());
                if (std.mem.eql(u8, marker, "__iterate__")) {
                    // (iterate f init) → rest is (iterate f (f init))
                    const f = payload[1];
                    var call_args = [_]Value{payload[2]};
                    const next_val = eval_mod.apply(f, &call_args, env, gc) catch return Value.makeObj(new);
                    const rest_obj = try gc.allocObj(.lazy_seq);
                    const rest_payload = try gc.allocObj(.vector);
                    try rest_payload.data.vector.items.append(gc.allocator, payload[0]); // marker
                    try rest_payload.data.vector.items.append(gc.allocator, f); // same fn
                    try rest_payload.data.vector.items.append(gc.allocator, next_val); // new init
                    rest_obj.data.lazy_seq.thunk = Value.makeObj(rest_payload);
                    return Value.makeObj(rest_obj);
                }
                if (std.mem.eql(u8, marker, "__range__")) {
                    // (range) with start, step → rest is (range) with start+step, step
                    const range_start = payload[1].asInt();
                    const range_step = payload[2].asInt();
                    const rest_obj = try gc.allocObj(.lazy_seq);
                    const rest_payload = try gc.allocObj(.vector);
                    try rest_payload.data.vector.items.append(gc.allocator, payload[0]); // marker
                    try rest_payload.data.vector.items.append(gc.allocator, Value.makeInt(range_start +% range_step));
                    try rest_payload.data.vector.items.append(gc.allocator, payload[2]); // same step
                    rest_obj.data.lazy_seq.thunk = Value.makeObj(rest_payload);
                    return Value.makeObj(rest_obj);
                }
                if (std.mem.eql(u8, marker, "__repeat__")) {
                    // (repeat val) → rest is same infinite repeat
                    // (repeat n val) → rest is (repeat (n-1) val)
                    if (payload.len >= 3 and payload[1].isInt()) {
                        const cnt = payload[1].asInt();
                        if (cnt <= 1) return Value.makeObj(new); // empty rest
                        const rest_obj = try gc.allocObj(.lazy_seq);
                        const rest_payload = try gc.allocObj(.vector);
                        try rest_payload.data.vector.items.append(gc.allocator, payload[0]);
                        try rest_payload.data.vector.items.append(gc.allocator, Value.makeInt(cnt - 1));
                        try rest_payload.data.vector.items.append(gc.allocator, payload[2]);
                        rest_obj.data.lazy_seq.thunk = Value.makeObj(rest_payload);
                        return Value.makeObj(rest_obj);
                    }
                    // Infinite repeat — return same lazy_seq
                    return args[0];
                }
                if (std.mem.eql(u8, marker, "__repeatedly__")) {
                    // (repeatedly f) → rest is same infinite repeatedly
                    return args[0];
                }
            }
        }
        // Generic lazy-seq: realize and return rest as list
        if (!thunk.isNil()) {
            const realized = eval_mod.apply(thunk, &.{}, env, gc) catch return Value.makeObj(new);
            if (realized.isObj()) {
                const ritems = getItems(realized) orelse return Value.makeObj(new);
                if (ritems.len > 1) {
                    for (ritems[1..]) |item| try new.data.list.items.append(gc.allocator, item);
                }
            }
        }
        return Value.makeObj(new);
    }
    const items = switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        else => return error.TypeError,
    };
    if (items.len > 1) {
        for (items[1..]) |item| try new.data.list.items.append(gc.allocator, item);
    }
    return Value.makeObj(new);
}

fn cons(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const new = try gc.allocObj(.list);
    try new.data.list.items.append(gc.allocator, args[0]);
    if (!args[1].isNil() and args[1].isObj()) {
        const obj = args[1].asObj();
        const items = switch (obj.kind) {
            .list => obj.data.list.items.items,
            .vector => obj.data.vector.items.items,
            else => return error.TypeError,
        };
        for (items) |item| try new.data.list.items.append(gc.allocator, item);
    }
    return Value.makeObj(new);
}

fn count(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil()) return Value.makeInt(0);
    // String count: return byte length
    if (args[0].isString()) {
        const s = gc.getString(args[0].asStringId());
        return Value.makeInt(@intCast(s.len));
    }
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    const n: i48 = @intCast(switch (obj.kind) {
        .list => obj.data.list.items.items.len,
        .vector => obj.data.vector.items.items.len,
        .map => obj.data.map.keys.items.len,
        .set => obj.data.set.items.items.len,
        else => return error.TypeError,
    });
    return Value.makeInt(n);
}

fn nth(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isObj() or !args[1].isInt()) return error.TypeError;
    const obj = args[0].asObj();
    const raw = args[1].asInt();
    if (raw < 0) return error.InvalidArgs;
    const idx: usize = std.math.cast(usize, raw) orelse return error.InvalidArgs;
    const items = switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        else => return error.TypeError,
    };
    if (idx >= items.len) return error.InvalidArgs;
    return items[idx];
}

fn getFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0].isNil()) return Value.makeNil();
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    if (obj.kind != .map) return error.TypeError;
    for (obj.data.map.keys.items, 0..) |k, i| {
        if (k.eql(args[1])) return obj.data.map.vals.items[i];
    }
    return Value.makeNil();
}

fn assoc(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 3 or (args.len - 1) % 2 != 0) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const src = args[0].asObj();
    if (src.kind != .map) return error.TypeError;
    const new = try gc.allocObj(.map);
    // copy existing
    for (src.data.map.keys.items, 0..) |k, i| {
        try new.data.map.keys.append(gc.allocator, k);
        try new.data.map.vals.append(gc.allocator, src.data.map.vals.items[i]);
    }
    var j: usize = 1;
    while (j < args.len) : (j += 2) {
        // replace or add
        var found = false;
        for (new.data.map.keys.items, 0..) |k, i| {
            if (k.eql(args[j])) {
                new.data.map.vals.items[i] = args[j + 1];
                found = true;
                break;
            }
        }
        if (!found) {
            try new.data.map.keys.append(gc.allocator, args[j]);
            try new.data.map.vals.append(gc.allocator, args[j + 1]);
        }
    }
    return Value.makeObj(new);
}

fn conj(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const src = args[0].asObj();
    switch (src.kind) {
        .list => {
            const new = try gc.allocObj(.list);
            // conj on list prepends
            var i = args.len;
            while (i > 1) {
                i -= 1;
                try new.data.list.items.append(gc.allocator, args[i]);
            }
            for (src.data.list.items.items) |item| try new.data.list.items.append(gc.allocator, item);
            return Value.makeObj(new);
        },
        .vector => {
            const new = try gc.allocObj(.vector);
            for (src.data.vector.items.items) |item| try new.data.vector.items.append(gc.allocator, item);
            for (args[1..]) |a| try new.data.vector.items.append(gc.allocator, a);
            return Value.makeObj(new);
        },
        else => return error.TypeError,
    }
}

// Predicates
fn isNilP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isNil());
}
fn isNumberP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isInt() or (!args[0].isNil() and !args[0].isBool() and !args[0].isSymbol() and !args[0].isKeyword() and !args[0].isString() and !args[0].isObj()));
}
fn isStringP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isString());
}
fn isKeywordP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isKeyword());
}
fn isSymbolP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isSymbol());
}
fn isListP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .list);
}
fn isVectorP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .vector);
}
fn isMapP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .map);
}
fn isFnP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .function);
}

// IO
fn printlnFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const stdout = compat.stdoutFile();
    for (args, 0..) |a, i| {
        if (i > 0) compat.fileWriteAll(stdout, " ");
        const s = try printer.prStr(a, gc, false);
        defer gc.allocator.free(s);
        compat.fileWriteAll(stdout, s);
    }
    compat.fileWriteAll(stdout, "\n");
    return Value.makeNil();
}

fn prStrFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    var buf = compat.emptyList(u8);
    for (args, 0..) |a, i| {
        if (i > 0) try buf.append(gc.allocator, ' ');
        try printer.prStrInto(&buf, a, gc, true);
    }
    const id = try gc.internString(buf.items);
    buf.deinit(gc.allocator);
    return Value.makeString(id);
}

fn readStringFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const s = gc.getString(args[0].asStringId());
    var r = reader_mod.Reader.init(s, gc);
    return r.readForm() catch Value.makeNil();
}

/// (load-file path) → result of last form
fn loadFileFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const path = gc.getString(args[0].asStringId());

    // Read file contents via C stdio (compat with 0.16)
    // Need null-terminated path for fopen
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return Value.makeNil();
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const c_path: [*c]const u8 = @ptrCast(&path_buf);
    const file = std.c.fopen(c_path, "r") orelse return Value.makeNil();
    defer _ = std.c.fclose(file);

    var contents = compat.emptyList(u8);
    defer contents.deinit(gc.allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&buf, 1, buf.len, file);
        if (n == 0) break;
        try contents.appendSlice(gc.allocator, buf[0..n]);
    }

    // Read and eval each form sequentially
    var r = reader_mod.Reader.init(contents.items, gc);
    var last_result = Value.makeNil();
    while (true) {
        const form = r.readForm() catch break;
        if (form.isNil()) {
            // Skip nil from comments, try next form
            if (r.pos >= r.src.len) break;
            continue;
        }
        last_result = eval_mod.eval(form, env, gc) catch Value.makeNil();
    }
    return last_result;
}

fn strFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    var buf = compat.emptyList(u8);
    for (args) |a| {
        try printer.prStrInto(&buf, a, gc, false);
    }
    const id = try gc.internString(buf.items);
    buf.deinit(gc.allocator);
    return Value.makeString(id);
}

fn subsFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    if (!args[0].isString() or !args[1].isInt()) return error.TypeError;
    const s = gc.getString(args[0].asStringId());
    const raw_start = args[1].asInt();
    if (raw_start < 0) return error.InvalidArgs;
    const start: usize = std.math.cast(usize, raw_start) orelse return error.InvalidArgs;
    const end: usize = if (args.len == 3 and args[2].isInt()) blk: {
        const raw_end = args[2].asInt();
        if (raw_end < 0) return error.InvalidArgs;
        break :blk std.math.cast(usize, raw_end) orelse return error.InvalidArgs;
    } else s.len;
    if (start > s.len or end > s.len or start > end) return error.InvalidArgs;
    const id = try gc.internString(s[start..end]);
    return Value.makeString(id);
}

// ── String operations ──

fn splitFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isString() or !args[1].isString()) return error.TypeError;
    const s = gc.getString(args[0].asStringId());
    const sep = gc.getString(args[1].asStringId());
    const obj = try gc.allocObj(.vector);
    if (sep.len == 0) {
        for (s) |byte| {
            try obj.data.vector.items.append(gc.allocator, Value.makeString(try gc.internString(&[_]u8{byte})));
        }
    } else {
        var start: usize = 0;
        while (start <= s.len) {
            if (simd_str.findSubstringPos(s, sep, start)) |idx| {
                try obj.data.vector.items.append(gc.allocator, Value.makeString(try gc.internString(s[start..idx])));
                start = idx + sep.len;
            } else {
                try obj.data.vector.items.append(gc.allocator, Value.makeString(try gc.internString(s[start..])));
                break;
            }
        }
    }
    return Value.makeObj(obj);
}

fn joinFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;
    const sep = if (args.len == 2 and args[0].isString()) gc.getString(args[0].asStringId()) else "";
    const coll_arg = if (args.len == 2) args[1] else args[0];
    if (!coll_arg.isObj()) return error.TypeError;
    const obj = coll_arg.asObj();
    const items = switch (obj.kind) {
        .vector => obj.data.vector.items.items,
        .list => obj.data.list.items.items,
        else => return error.TypeError,
    };
    var buf = compat.emptyList(u8);
    defer buf.deinit(gc.allocator);
    for (items, 0..) |item, i| {
        if (i > 0) try buf.appendSlice(gc.allocator, sep);
        if (item.isString()) {
            try buf.appendSlice(gc.allocator, gc.getString(item.asStringId()));
        } else {
            const s = try printer.prStr(item, gc, false);
            try buf.appendSlice(gc.allocator, s);
        }
    }
    return Value.makeString(try gc.internString(buf.items));
}

fn replaceFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    if (!args[0].isString() or !args[1].isString() or !args[2].isString()) return error.TypeError;
    const s = gc.getString(args[0].asStringId());
    const from = gc.getString(args[1].asStringId());
    const to = gc.getString(args[2].asStringId());
    if (from.len == 0) return args[0];
    var buf = compat.emptyList(u8);
    defer buf.deinit(gc.allocator);
    var pos: usize = 0;
    while (pos < s.len) {
        if (simd_str.findSubstringPos(s, from, pos)) |idx| {
            try buf.appendSlice(gc.allocator, s[pos..idx]);
            try buf.appendSlice(gc.allocator, to);
            pos = idx + from.len;
        } else {
            try buf.appendSlice(gc.allocator, s[pos..]);
            break;
        }
    }
    return Value.makeString(try gc.internString(buf.items));
}

fn indexOfFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    if (!args[0].isString() or !args[1].isString()) return error.TypeError;
    const s = gc.getString(args[0].asStringId());
    const needle = gc.getString(args[1].asStringId());
    const from: usize = if (args.len == 3 and args[2].isInt())
        std.math.cast(usize, @max(@as(i48, 0), args[2].asInt())) orelse 0
    else
        0;
    if (simd_str.findSubstringPos(s, needle, from)) |idx| {
        return Value.makeInt(@intCast(idx));
    }
    return Value.makeInt(-1);
}

fn startsWithFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isString() or !args[1].isString()) return error.TypeError;
    return Value.makeBool(std.mem.startsWith(u8, gc.getString(args[0].asStringId()), gc.getString(args[1].asStringId())));
}

fn endsWithFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isString() or !args[1].isString()) return error.TypeError;
    return Value.makeBool(std.mem.endsWith(u8, gc.getString(args[0].asStringId()), gc.getString(args[1].asStringId())));
}

fn trimFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    const s = gc.getString(args[0].asStringId());
    const trimmed = std.mem.trim(u8, s, " \t\n\r");
    return Value.makeString(try gc.internString(trimmed));
}

fn upperCaseFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    const s = gc.getString(args[0].asStringId());
    var buf = try gc.allocator.alloc(u8, s.len);
    defer gc.allocator.free(buf);
    for (s, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return Value.makeString(try gc.internString(buf));
}

fn lowerCaseFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    const s = gc.getString(args[0].asStringId());
    var buf = try gc.allocator.alloc(u8, s.len);
    defer gc.allocator.free(buf);
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return Value.makeString(try gc.internString(buf));
}

fn charAtFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isString() or !args[1].isInt()) return error.TypeError;
    const s = gc.getString(args[0].asStringId());
    const idx = args[1].asInt();
    if (idx < 0 or idx >= @as(i48, @intCast(s.len))) return Value.makeNil();
    return Value.makeString(try gc.internString(&[_]u8{s[@intCast(idx)]}));
}

fn stringLengthFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    return Value.makeInt(@intCast(gc.getString(args[0].asStringId()).len));
}

fn notFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(!args[0].isTruthy());
}

// ── Splittable RNG (SplitMix64) ──

fn splitMix64(seed: u64) u64 {
    var z = seed +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

// ── Universal index-addressed builtins ──

/// (at seed index) → deterministic u64 value. The single primitive.
fn atFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const index: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    const v = substrate.at(seed, index);
    return Value.makeInt(@intCast(@as(i48, @truncate(@as(i64, @bitCast(v))))));
}

/// (trit-at seed index) → -1, 0, or 1. GF(3) projection of at().
fn tritAtFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const index: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    return Value.makeInt(@as(i48, substrate.tritAt(seed, index)));
}

/// (trit-sum seed n) → sum of trits [0, n). GF(3) conservation check.
fn tritSumFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const n: u64 = @intCast(@max(@as(i48, 0), @min(args[1].asInt(), 100000)));
    return Value.makeInt(@as(i48, substrate.tritSum(seed, n)));
}

/// (find-balancer a b) → c such that a+b+c ≡ 0 mod 3. boxxy/GF3.dfy proven.
fn findBalancerFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const a: i8 = @intCast(@max(@as(i48, -1), @min(args[0].asInt(), 1)));
    const b: i8 = @intCast(@max(@as(i48, -1), @min(args[1].asInt(), 1)));
    return Value.makeInt(@as(i48, substrate.findBalancer(a, b)));
}

/// (trit-of hash-value) → content-based trit. Independent of position.
fn tritOfContentFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const h: u64 = @bitCast(@as(i64, args[0].asInt()));
    return Value.makeInt(@as(i48, substrate.tritOfContent(h)));
}

fn incFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    return Value.makeInt(args[0].asInt() +% 1);
}

fn decFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    return Value.makeInt(args[0].asInt() -% 1);
}

fn isZeroP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return Value.makeBool(false);
    return Value.makeBool(args[0].asInt() == 0);
}

fn applyFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const func = args[0];
    const last = args[args.len - 1];
    var real_args = compat.emptyList(Value);
    defer real_args.deinit(gc.allocator);
    for (args[1 .. args.len - 1]) |a| try real_args.append(gc.allocator, a);
    if (last.isObj()) {
        const obj = last.asObj();
        const items = switch (obj.kind) {
            .list => obj.data.list.items.items,
            .vector => obj.data.vector.items.items,
            else => return error.TypeError,
        };
        for (items) |item| try real_args.append(gc.allocator, item);
    }
    // Check if builtin
    if (isBuiltinSentinel(func, gc)) |name| {
        if (lookupBuiltin(name)) |builtin| {
            return builtin(real_args.items, gc, env);
        }
    }
    return eval_mod.apply(func, real_args.items, env, gc);
}

fn takeFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const n: usize = @intCast(@max(@as(i48, 0), args[0].asInt()));
    if (args[1].isNil()) return Value.makeObj(try gc.allocObj(.list));
    if (!args[1].isObj()) return error.TypeError;
    const obj = args[1].asObj();
    // Handle lazy-seq: realize n elements by inspecting the thunk marker
    if (obj.kind == .lazy_seq) {
        const result = try gc.allocObj(.list);
        const thunk = obj.data.lazy_seq.thunk;
        if (thunk.isObj() and thunk.asObj().kind == .vector) {
            const payload = thunk.asObj().data.vector.items.items;
            if (payload.len >= 2 and payload[0].isKeyword()) {
                const marker = gc.getString(payload[0].asKeywordId());
                if (std.mem.eql(u8, marker, "__repeat__")) {
                    // (repeat val) or (repeat n val)
                    const val = if (payload.len >= 3) payload[2] else payload[1];
                    const limit = if (payload.len >= 3 and payload[1].isInt())
                        @min(n, @as(usize, @intCast(@max(@as(i48, 0), payload[1].asInt()))))
                    else n;
                    for (0..limit) |_| try result.data.list.items.append(gc.allocator, val);
                    return Value.makeObj(result);
                }
                if (std.mem.eql(u8, marker, "__iterate__")) {
                    // (iterate f init)
                    const f = payload[1];
                    var current = payload[2];
                    for (0..n) |_| {
                        try result.data.list.items.append(gc.allocator, current);
                        var call_args = [_]Value{current};
                        current = eval_mod.apply(f, &call_args, env, gc) catch break;
                    }
                    return Value.makeObj(result);
                }
                if (std.mem.eql(u8, marker, "__repeatedly__")) {
                    // (repeatedly f) — call f n times
                    const f = payload[1];
                    for (0..n) |_| {
                        const val = eval_mod.apply(f, &.{}, env, gc) catch break;
                        try result.data.list.items.append(gc.allocator, val);
                    }
                    return Value.makeObj(result);
                }
                if (std.mem.eql(u8, marker, "__range__")) {
                    // (range) — infinite lazy range: start, start+step, ...
                    const range_start = payload[1].asInt();
                    const range_step = payload[2].asInt();
                    var current = range_start;
                    for (0..n) |_| {
                        try result.data.list.items.append(gc.allocator, Value.makeInt(current));
                        current +%= range_step;
                    }
                    return Value.makeObj(result);
                }
            }
        }
        // Generic lazy-seq: try calling thunk as zero-arg fn
        if (!thunk.isNil()) {
            const realized = eval_mod.apply(thunk, &.{}, env, gc) catch return Value.makeObj(result);
            if (realized.isObj()) {
                const ritems = getItems(realized) orelse return Value.makeObj(result);
                const limit = @min(n, ritems.len);
                for (ritems[0..limit]) |item| try result.data.list.items.append(gc.allocator, item);
            }
        }
        return Value.makeObj(result);
    }
    const items = switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        else => return error.TypeError,
    };
    const new = try gc.allocObj(.list);
    const limit = @min(n, items.len);
    for (items[0..limit]) |item| try new.data.list.items.append(gc.allocator, item);
    return Value.makeObj(new);
}

fn dropFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const n: usize = @intCast(@max(@as(i48, 0), args[0].asInt()));
    if (args[1].isNil()) return Value.makeObj(try gc.allocObj(.list));
    if (!args[1].isObj()) return error.TypeError;
    const obj = args[1].asObj();
    const items = switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        else => return error.TypeError,
    };
    const new = try gc.allocObj(.list);
    const start = @min(n, items.len);
    for (items[start..]) |item| try new.data.list.items.append(gc.allocator, item);
    return Value.makeObj(new);
}

fn reduceFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    // (reduce f init coll) or (reduce f coll)
    if (args.len < 2 or args.len > 3) return error.ArityError;
    const func = args[0];
    var acc: Value = undefined;
    var items: []Value = undefined;

    if (args.len == 3) {
        acc = args[1];
        if (args[2].isNil()) return acc;
        if (!args[2].isObj()) return error.TypeError;
        const obj = args[2].asObj();
        items = switch (obj.kind) {
            .list => obj.data.list.items.items,
            .vector => obj.data.vector.items.items,
            else => return error.TypeError,
        };
    } else {
        if (args[1].isNil()) {
            // (reduce f '()) — call f with no args
            if (isBuiltinSentinel(func, gc)) |name| {
                if (lookupBuiltin(name)) |builtin| {
                    const empty: []Value = &.{};
                    return builtin(empty, gc, env);
                }
            }
            return eval_mod.apply(func, &.{}, env, gc);
        }
        if (!args[1].isObj()) return error.TypeError;
        const obj = args[1].asObj();
        items = switch (obj.kind) {
            .list => obj.data.list.items.items,
            .vector => obj.data.vector.items.items,
            else => return error.TypeError,
        };
        if (items.len == 0) {
            if (isBuiltinSentinel(func, gc)) |name| {
                if (lookupBuiltin(name)) |builtin| {
                    const empty: []Value = &.{};
                    return builtin(empty, gc, env);
                }
            }
            return eval_mod.apply(func, &.{}, env, gc);
        }
        acc = items[0];
        items = items[1..];
    }

    for (items) |item| {
        var pair = [2]Value{ acc, item };
        if (isBuiltinSentinel(func, gc)) |name| {
            if (lookupBuiltin(name)) |builtin| {
                acc = try builtin(&pair, gc, env);
                continue;
            }
        }
        acc = try eval_mod.apply(func, &pair, env, gc);
    }
    return acc;
}

fn rangeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    // (range) — infinite lazy sequence 0, 1, 2, ...
    // (range end), (range start end), (range start end step)
    if (args.len > 3) return error.ArityError;

    // Zero-arity: infinite lazy range starting from 0
    if (args.len == 0) {
        const obj = try gc.allocObj(.lazy_seq);
        const payload = try gc.allocObj(.vector);
        const marker = Value.makeKeyword(try gc.internString("__range__"));
        try payload.data.vector.items.append(gc.allocator, marker);
        try payload.data.vector.items.append(gc.allocator, Value.makeInt(0)); // start
        try payload.data.vector.items.append(gc.allocator, Value.makeInt(1)); // step
        obj.data.lazy_seq.thunk = Value.makeObj(payload);
        return Value.makeObj(obj);
    }

    var start: i48 = 0;
    var end: i48 = undefined;
    var step: i48 = 1;

    if (args.len == 1) {
        if (!args[0].isInt()) return error.TypeError;
        end = args[0].asInt();
    } else {
        if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
        start = args[0].asInt();
        end = args[1].asInt();
        if (args.len == 3) {
            if (!args[2].isInt()) return error.TypeError;
            step = args[2].asInt();
        }
    }
    if (step == 0) return error.InvalidArgs;

    const new = try gc.allocObj(.list);
    var i = start;
    if (step > 0) {
        while (i < end) : (i += step) {
            try new.data.list.items.append(gc.allocator, Value.makeInt(i));
        }
    } else {
        while (i > end) : (i += step) {
            try new.data.list.items.append(gc.allocator, Value.makeInt(i));
        }
    }
    return Value.makeObj(new);
}

fn getItems(val: Value) ?[]Value {
    if (val.isNil()) return &.{};
    if (!val.isObj()) return null;
    const obj = val.asObj();
    return switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        .set => obj.data.set.items.items,
        else => null,
    };
}

fn mapFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const func = args[0];
    const items = getItems(args[1]) orelse return error.TypeError;
    const new = try gc.allocObj(.list);
    const core = @import("core.zig");
    for (items) |item| {
        var a = [1]Value{item};
        const v = if (core.isBuiltinSentinel(func, gc)) |name|
            (if (core.lookupBuiltin(name)) |builtin| try builtin(&a, gc, env) else try eval_mod.apply(func, &a, env, gc))
        else
            try eval_mod.apply(func, &a, env, gc);
        try new.data.list.items.append(gc.allocator, v);
    }
    return Value.makeObj(new);
}

fn filterFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const func = args[0];
    const items = getItems(args[1]) orelse return error.TypeError;
    const new = try gc.allocObj(.list);
    const core = @import("core.zig");
    for (items) |item| {
        var a = [1]Value{item};
        const v = if (core.isBuiltinSentinel(func, gc)) |name|
            (if (core.lookupBuiltin(name)) |builtin| try builtin(&a, gc, env) else try eval_mod.apply(func, &a, env, gc))
        else
            try eval_mod.apply(func, &a, env, gc);
        if (v.isTruthy()) {
            try new.data.list.items.append(gc.allocator, item);
        }
    }
    return Value.makeObj(new);
}

fn concatFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const new = try gc.allocObj(.list);
    for (args) |arg| {
        const items = getItems(arg) orelse continue;
        for (items) |item| try new.data.list.items.append(gc.allocator, item);
    }
    return Value.makeObj(new);
}

fn reverseFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;
    const new = try gc.allocObj(.list);
    var i = items.len;
    while (i > 0) {
        i -= 1;
        try new.data.list.items.append(gc.allocator, items[i]);
    }
    return Value.makeObj(new);
}

fn isEmptyP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil()) return Value.makeBool(true);
    const items = getItems(args[0]) orelse return error.TypeError;
    return Value.makeBool(items.len == 0);
}

fn intoFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const target = args[0].asObj();
    const src_items = getItems(args[1]) orelse return error.TypeError;
    switch (target.kind) {
        .vector => {
            const new = try gc.allocObj(.vector);
            for (target.data.vector.items.items) |item| try new.data.vector.items.append(gc.allocator, item);
            for (src_items) |item| try new.data.vector.items.append(gc.allocator, item);
            return Value.makeObj(new);
        },
        .list => {
            const new = try gc.allocObj(.list);
            for (target.data.list.items.items) |item| try new.data.list.items.append(gc.allocator, item);
            for (src_items) |item| try new.data.list.items.append(gc.allocator, item);
            return Value.makeObj(new);
        },
        .set => {
            const new = try gc.allocObj(.set);
            for (target.data.set.items.items) |item| try new.data.set.items.append(gc.allocator, item);
            for (src_items) |item| {
                var found = false;
                for (new.data.set.items.items) |existing| {
                    if (existing.eql(item)) { found = true; break; }
                }
                if (!found) try new.data.set.items.append(gc.allocator, item);
            }
            return Value.makeObj(new);
        },
        else => return error.TypeError,
    }
}

fn isSetP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .set);
}

fn isSeqP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .list);
}

fn isSequentialP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj()) return Value.makeBool(false);
    const k = args[0].asObj().kind;
    return Value.makeBool(k == .list or k == .vector);
}

// ── Trit-tick time quantum builtins ──────────────────────────────

const transitivity = @import("transitivity.zig");
const jepsen = @import("jepsen.zig");
const pat_mod = @import("pattern.zig");

/// (trit-phase n) → -1, 0, or 1 — GF(3) phase of tick count n
fn tritPhaseFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const n: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    return Value.makeInt(@as(i48, transitivity.tritPhase(n)));
}

/// (frames->trit-ticks frames fps) → integer trit-ticks
fn framesToTritTicksFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const frames: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const fps: u32 = @intCast(@max(@as(i48, 1), args[1].asInt()));
    return Value.makeInt(@intCast(transitivity.framesToTritTicks(frames, fps)));
}

/// (samples->trit-ticks samples rate) → integer trit-ticks
fn samplesToTritTicksFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const samples: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const rate: u32 = @intCast(@max(@as(i48, 1), args[1].asInt()));
    return Value.makeInt(@intCast(transitivity.samplesToTritTicks(samples, rate)));
}

/// (trit-ticks-per-sec) → 2116800000
fn tritTicksPerSecFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(@intCast(transitivity.TRIT_TICKS_PER_SEC));
}

/// (flicks-per-sec) → 705600000
fn flicksPerSecFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(@intCast(transitivity.FLICK));
}

/// (glimpses-per-tick) → 1069
fn glimpsesPerTickFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(1069);
}

/// (cognitive-jerk tick-count glimpse-count) → -1, 0, or 1
/// Measures phase alignment between objective time (ticks) and
/// subjective microstructure (glimpses).
/// 0 = flow (aligned), 1 = anticipation (leading), -1 = drag (lagging)
fn cognitiveJerkFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const ticks: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const glimpses: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    var tt = transitivity.TritTime{ .ticks = ticks, .glimpses = glimpses };
    _ = &tt;
    return Value.makeInt(@as(i48, tt.jerk()));
}

/// (p-adic p n) → v_p(n), the p-adic valuation (highest power of p dividing n)
fn padicFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const p: u64 = @intCast(@max(@as(i48, 2), args[0].asInt()));
    const n: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    return Value.makeInt(@intCast(transitivity.padicVal(p, n)));
}

/// (p-adic-depth n) → (v2 v3 v5 v7 v1069) — multi-prime ultrametric fingerprint
fn padicDepthFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const n: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const d = transitivity.PadicDepth.of(n);
    const new = try gc.allocObj(.list);
    for (d.v) |vi| {
        try new.data.list.items.append(gc.allocator, Value.makeInt(@intCast(vi)));
    }
    return Value.makeObj(new);
}

// ============================================================================
// INFORMATION SPACETIME BUILTINS
// ============================================================================

/// (separation distance budget) → -1 (spacelike), 0 (lightlike), 1 (timelike)
fn separationFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const dist: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const budget: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    return Value.makeInt(@as(i48, transitivity.classify(dist, budget).trit()));
}

/// (cone-volume branching depth) → number of nodes reachable
fn coneVolumeFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const b: u64 = @intCast(@max(@as(i48, 1), args[0].asInt()));
    const d: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    const vol = transitivity.coneVolume(b, d);
    return Value.makeInt(@intCast(@min(vol, @as(u64, @intCast(std.math.maxInt(i48))))));
}

/// (info-density nodes volume) → density × 1000 (fixed-point)
fn infoDensityFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const nodes: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const volume: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    return Value.makeInt(@intCast(transitivity.infoDensity(nodes, volume)));
}

/// (causal-depth branching target-volume) → ticks needed
fn causalDepthFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const b: u64 = @intCast(@max(@as(i48, 1), args[0].asInt()));
    const v: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    return Value.makeInt(@intCast(transitivity.causalDepth(b, v)));
}

/// (padic-cones depth) → [vol₂ vol₃ vol₅ vol₇ vol₁₀₆₉]
fn padicConesFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const d: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const cones = transitivity.padicCones(d);
    const obj = try gc.allocObj(.vector);
    for (cones) |vol| {
        const clamped = @min(vol, @as(u64, @intCast(std.math.maxInt(i48))));
        try obj.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(clamped)));
    }
    return Value.makeObj(obj);
}

// ============================================================================
// JEPSEN BUILTINS: embedded linearizability testing
// ============================================================================

/// (jepsen/nemesis! kind) → previous-kind
/// Kinds: :none :trit-corrupt :trit-duplicate :version-rewind :eval-drop :causal-invert
fn jepsenNemesisFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const kind: jepsen.NemesisKind = if (args[0].isKeyword()) blk: {
        const name = gc.getString(args[0].asKeywordId());
        if (std.mem.eql(u8, name, "none")) break :blk .none
        else if (std.mem.eql(u8, name, "trit-corrupt")) break :blk .trit_corrupt
        else if (std.mem.eql(u8, name, "trit-duplicate")) break :blk .trit_duplicate
        else if (std.mem.eql(u8, name, "version-rewind")) break :blk .version_rewind
        else if (std.mem.eql(u8, name, "eval-drop")) break :blk .eval_drop
        else if (std.mem.eql(u8, name, "causal-invert")) break :blk .causal_invert
        else break :blk .none;
    } else if (args[0].isInt()) blk: {
        const v = args[0].asInt();
        break :blk if (v >= 0 and v <= 5) @enumFromInt(@as(u8, @intCast(v))) else .none;
    } else return error.TypeError;

    const prev = jepsen.activateNemesis(kind);
    return Value.makeInt(@as(i48, @intFromEnum(prev)));
}

/// (jepsen/gen n seed) → vector of [op-kind detail] pairs
fn jepsenGenFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const n: usize = @intCast(@max(@as(i48, 1), args[0].asInt()));
    const seed: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    const clamped_n = @min(n, 1000); // safety cap

    var buf: [1000]jepsen.HistoryEntry = undefined;
    const gen_count = jepsen.generatePlan(seed, clamped_n, &buf);

    const obj = try gc.allocObj(.vector);
    for (0..gen_count) |i| {
        const entry_obj = try gc.allocObj(.vector);
        const op_name: []const u8 = switch (buf[i].op) {
            .eval => "eval",
            .nemesis => "nemesis",
            .recover => "recover",
            .check => "check",
        };
        try entry_obj.data.vector.items.append(gc.allocator, Value.makeKeyword(try gc.internString(op_name)));
        try entry_obj.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(buf[i].detail)));
        try obj.data.vector.items.append(gc.allocator, Value.makeObj(entry_obj));
    }
    return Value.makeObj(obj);
}

/// (jepsen/record! op-kind result trit-before trit-after version-id) → causal-ts
fn jepsenRecordFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = gc;
    if (args.len < 4) return error.ArityError;
    const op: jepsen.OpKind = if (args[0].isInt())
        @enumFromInt(@as(u8, @intCast(@max(@as(i48, 0), args[0].asInt()))))
    else
        .eval;
    const result_kind: jepsen.OpResult = if (args[1].isInt())
        @enumFromInt(@as(u8, @intCast(@max(@as(i48, 0), args[1].asInt()))))
    else
        .ok;
    const trit_before: i8 = if (args[2].isInt()) @intCast(@max(@as(i48, -1), @min(args[2].asInt(), 1))) else 0;
    const trit_after: i8 = if (args[3].isInt()) @intCast(@max(@as(i48, -1), @min(args[3].asInt(), 1))) else 0;
    const version_id: u64 = if (args.len > 4 and args[4].isInt()) @intCast(@max(@as(i48, 0), args[4].asInt())) else 0;
    const detail: u32 = if (args.len > 5 and args[5].isInt()) @intCast(@max(@as(i48, 0), args[5].asInt())) else 0;

    jepsen.record(op, result_kind, trit_before, trit_after, version_id, detail);
    return Value.makeInt(@intCast(jepsen.causal_clock));
}

/// (jepsen/check) → {:valid? bool :violations N :ops-checked N :nemesis-events N :max-trit-drift N}
fn jepsenCheckFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const result = jepsen.check();

    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("valid?")));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(result.valid));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("violations")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(result.violation_count)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("ops-checked")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(result.ops_checked)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("nemesis-events")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(result.nemesis_events)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("max-trit-drift")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@as(i48, result.max_trit_drift)));
    return Value.makeObj(obj);
}

/// (jepsen/reset!) → nil
fn jepsenResetFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    _ = args;
    jepsen.resetHistory();
    return Value.makeNil();
}

/// (jepsen/history) → vector of maps (recent history entries)
fn jepsenHistoryFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const hist = jepsen.getHistory();
    const obj = try gc.allocObj(.vector);
    const limit = @min(hist.len, 100); // cap at 100 entries for display
    for (0..limit) |i| {
        const entry = hist[i];
        const entry_obj = try gc.allocObj(.map);
        try entry_obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("op")));
        const op_name: []const u8 = switch (entry.op) {
            .eval => "eval",
            .nemesis => "nemesis",
            .recover => "recover",
            .check => "check",
        };
        try entry_obj.data.map.vals.append(gc.allocator, Value.makeKeyword(try gc.internString(op_name)));
        try entry_obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("result")));
        const res_name: []const u8 = switch (entry.result) {
            .ok => "ok",
            .fail => "fail",
            .info => "info",
        };
        try entry_obj.data.map.vals.append(gc.allocator, Value.makeKeyword(try gc.internString(res_name)));
        try entry_obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("ts")));
        try entry_obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(entry.causal_ts)));
        try entry_obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("trit")));
        try entry_obj.data.map.vals.append(gc.allocator, Value.makeInt(@as(i48, entry.trit_after)));
        try obj.data.vector.items.append(gc.allocator, Value.makeObj(entry_obj));
    }
    return Value.makeObj(obj);
}

/// (jepsen/check-unique-ids) → {:valid? bool :attempted N :duplicated N :min-id N :max-id N}
fn jepsenCheckUniqueIdsFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const r = jepsen.checkUniqueIds();
    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("valid?")));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(r.valid));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("attempted")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.attempted)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("duplicated")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.duplicated)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("min-id")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.min_id)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("max-id")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.max_id)));
    return Value.makeObj(obj);
}

/// (jepsen/check-counter) → {:valid? bool :reads N :errors N :lower N :upper N}
fn jepsenCheckCounterFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const r = jepsen.checkCounter();
    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("valid?")));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(r.valid));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("reads")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.reads)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("errors")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.errors)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("lower")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@min(r.lower_bound, @as(u64, @intCast(std.math.maxInt(i48)))))));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("upper")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@min(r.upper_bound, @as(u64, @intCast(std.math.maxInt(i48)))))));
    return Value.makeObj(obj);
}

/// (jepsen/check-cas-register) → {:valid? bool :reads N :writes N :cas-ops N :stale-reads N :lost-writes N :value N}
fn jepsenCheckCasRegisterFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const r = jepsen.checkCasRegister();
    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("valid?")));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(r.valid));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("reads")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.reads)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("writes")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.writes)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("cas-ops")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.cas_ops)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("stale-reads")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.stale_reads)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("lost-writes")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.lost_writes)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("value")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.register_value)));
    return Value.makeObj(obj);
}

// ============================================================================
// SPLITTABLE RNG BUILTINS
// ============================================================================
// RNG state is a 2-element vector [seed gamma].
// Purely functional: each operation returns a new state + value.

fn rngFromVec(args: []Value, gc: *GC) ?substrate.SplitRng {
    if (args.len < 1) return null;
    if (args[0].isInt()) return substrate.SplitRng.init(@intCast(@max(@as(i48, 0), args[0].asInt())));
    if (!args[0].isObj()) return null;
    const obj = args[0].asObj();
    if (obj.kind != .vector) return null;
    const items = obj.data.vector.items.items;
    if (items.len < 2 or !items[0].isInt() or !items[1].isInt()) return null;
    _ = gc;
    return .{
        .seed = @intCast(@max(@as(i48, 0), items[0].asInt())),
        .gamma = @intCast(@max(@as(i48, 1), items[1].asInt())),
    };
}

fn rngToVec(rng: substrate.SplitRng, gc: *GC) !Value {
    const obj = try gc.allocObj(.vector);
    try obj.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(@as(i48, @truncate(@as(i64, @bitCast(rng.seed)))))));
    try obj.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(@as(i48, @truncate(@as(i64, @bitCast(rng.gamma)))))));
    return Value.makeObj(obj);
}

/// (split-rng seed) → [seed gamma] — create a splittable RNG from seed
fn splitRngFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.TypeError;
    const seed: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    return rngToVec(substrate.SplitRng.init(seed), gc);
}

/// (rng-next rng) → [value new-rng] — next value + advanced state
fn rngNextFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    var rng = rngFromVec(args, gc) orelse return error.TypeError;
    const val = rng.next();
    const obj = try gc.allocObj(.vector);
    try obj.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(@as(i48, @truncate(@as(i64, @bitCast(val)))))));
    try obj.data.vector.items.append(gc.allocator, try rngToVec(rng, gc));
    return Value.makeObj(obj);
}

/// (rng-split rng) → [left-rng right-rng] — fork into two independent streams
fn rngSplitFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    var rng = rngFromVec(args, gc) orelse return error.TypeError;
    const right = rng.split();
    const obj = try gc.allocObj(.vector);
    try obj.data.vector.items.append(gc.allocator, try rngToVec(rng, gc));
    try obj.data.vector.items.append(gc.allocator, try rngToVec(right, gc));
    return Value.makeObj(obj);
}

/// (rng-trit rng) → [trit new-rng] — next GF(3) trit + advanced state
fn rngTritFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    var rng = rngFromVec(args, gc) orelse return error.TypeError;
    const gf3 = rng.nextGF3();
    const obj = try gc.allocObj(.vector);
    try obj.data.vector.items.append(gc.allocator, Value.makeInt(@as(i48, gf3.trit)));
    try obj.data.vector.items.append(gc.allocator, try rngToVec(rng, gc));
    return Value.makeObj(obj);
}

// ============================================================================
// CORE DATA OPS
// ============================================================================

fn dissocFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const src = args[0].asObj();
    if (src.kind != .map) return error.TypeError;
    const obj = try gc.allocObj(.map);
    const keys = src.data.map.keys.items;
    const vals = src.data.map.vals.items;
    for (keys, vals) |k, v| {
        var skip = false;
        for (args[1..]) |dk| {
            if (semantics.structuralEq(k, dk, gc)) { skip = true; break; }
        }
        if (!skip) {
            try obj.data.map.keys.append(gc.allocator, k);
            try obj.data.map.vals.append(gc.allocator, v);
        }
    }
    return Value.makeObj(obj);
}

fn updateFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 3) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const src = args[0].asObj();
    if (src.kind != .map) return error.TypeError;
    const key = args[1];
    const f = args[2];
    const obj = try gc.allocObj(.map);
    const keys = src.data.map.keys.items;
    const vals = src.data.map.vals.items;
    var found = false;
    for (keys, vals) |k, v| {
        try obj.data.map.keys.append(gc.allocator, k);
        if (semantics.structuralEq(k, key, gc)) {
            var call_args = [_]Value{v} ++ [_]Value{Value.makeNil()} ** 3;
            const extra = args[3..];
            const n = @min(extra.len, 3);
            for (0..n) |i| call_args[1 + i] = extra[i];
            const new_val = try eval_mod.apply(f, call_args[0 .. 1 + n], env, gc);
            try obj.data.map.vals.append(gc.allocator, new_val);
            found = true;
        } else {
            try obj.data.map.vals.append(gc.allocator, v);
        }
    }
    if (!found) {
        try obj.data.map.keys.append(gc.allocator, key);
        var call_args = [_]Value{Value.makeNil()} ** 4;
        const extra = args[3..];
        const n = @min(extra.len, 3);
        for (0..n) |i| call_args[1 + i] = extra[i];
        const new_val = try eval_mod.apply(f, call_args[0 .. 1 + n], env, gc);
        try obj.data.map.vals.append(gc.allocator, new_val);
    }
    return Value.makeObj(obj);
}

fn mergeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len == 0) return Value.makeNil();
    const obj = try gc.allocObj(.map);
    for (args) |a| {
        if (a.isNil()) continue;
        if (!a.isObj()) return error.TypeError;
        const m = a.asObj();
        if (m.kind != .map) return error.TypeError;
        for (m.data.map.keys.items, m.data.map.vals.items) |k, v| {
            // overwrite existing key
            var replaced = false;
            for (obj.data.map.keys.items, 0..) |ek, i| {
                if (semantics.structuralEq(ek, k, gc)) {
                    obj.data.map.vals.items[i] = v;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) {
                try obj.data.map.keys.append(gc.allocator, k);
                try obj.data.map.vals.append(gc.allocator, v);
            }
        }
    }
    return Value.makeObj(obj);
}

fn selectKeysFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isObj() or !args[1].isObj()) return error.TypeError;
    const src = args[0].asObj();
    const ks = args[1].asObj();
    if (src.kind != .map) return error.TypeError;
    const wanted = switch (ks.kind) {
        .vector => ks.data.vector.items.items,
        .list => ks.data.list.items.items,
        else => return error.TypeError,
    };
    const obj = try gc.allocObj(.map);
    for (wanted) |wk| {
        for (src.data.map.keys.items, src.data.map.vals.items) |k, v| {
            if (semantics.structuralEq(k, wk, gc)) {
                try obj.data.map.keys.append(gc.allocator, k);
                try obj.data.map.vals.append(gc.allocator, v);
                break;
            }
        }
    }
    return Value.makeObj(obj);
}

fn keysFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil()) return Value.makeNil();
    if (!args[0].isObj()) return error.TypeError;
    const m = args[0].asObj();
    if (m.kind != .map) return error.TypeError;
    const obj = try gc.allocObj(.list);
    for (m.data.map.keys.items) |k| {
        try obj.data.list.items.append(gc.allocator, k);
    }
    return Value.makeObj(obj);
}

fn valsFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil()) return Value.makeNil();
    if (!args[0].isObj()) return error.TypeError;
    const m = args[0].asObj();
    if (m.kind != .map) return error.TypeError;
    const obj = try gc.allocObj(.list);
    for (m.data.map.vals.items) |v| {
        try obj.data.list.items.append(gc.allocator, v);
    }
    return Value.makeObj(obj);
}

fn containsFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0].isNil()) return Value.makeBool(false);
    if (!args[0].isObj()) return error.TypeError;
    const o = args[0].asObj();
    return switch (o.kind) {
        .map => blk: {
            for (o.data.map.keys.items) |k| {
                if (semantics.structuralEq(k, args[1], gc)) break :blk Value.makeBool(true);
            }
            break :blk Value.makeBool(false);
        },
        .set => blk: {
            for (o.data.set.items.items) |item| {
                if (semantics.structuralEq(item, args[1], gc)) break :blk Value.makeBool(true);
            }
            break :blk Value.makeBool(false);
        },
        .vector => blk: {
            if (!args[1].isInt()) break :blk Value.makeBool(false);
            const idx = args[1].asInt();
            break :blk Value.makeBool(idx >= 0 and idx < @as(i48, @intCast(o.data.vector.items.items.len)));
        },
        else => error.TypeError,
    };
}

// ============================================================================
// SEQUENCE EXTRAS
// ============================================================================

fn secondFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = try seqItems(args[0], gc);
    return if (items.len > 1) items[1] else Value.makeNil();
}

fn lastFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = try seqItems(args[0], gc);
    return if (items.len > 0) items[items.len - 1] else Value.makeNil();
}

fn someFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const f = args[0];
    const items = try seqItems(args[1], gc);
    for (items) |item| {
        var a = [_]Value{item};
        const r = try eval_mod.apply(f, &a, env, gc);
        if (r.isTruthy()) return r;
    }
    return Value.makeNil();
}

fn everyFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const f = args[0];
    const items = try seqItems(args[1], gc);
    for (items) |item| {
        var a = [_]Value{item};
        const r = try eval_mod.apply(f, &a, env, gc);
        if (!r.isTruthy()) return Value.makeBool(false);
    }
    return Value.makeBool(true);
}

fn notAnyFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const r = try someFn(args, gc, env);
    return Value.makeBool(r.isNil());
}

fn sortFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = try seqItems(args[0], gc);
    const obj = try gc.allocObj(.vector);
    try obj.data.vector.items.appendSlice(gc.allocator, items);
    std.sort.insertion(Value, obj.data.vector.items.items, gc, valueLessThan);
    return Value.makeObj(obj);
}

fn sortByFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const keyfn = args[0];
    const items = try seqItems(args[1], gc);
    const obj = try gc.allocObj(.vector);
    try obj.data.vector.items.appendSlice(gc.allocator, items);
    // Compute keys, then sort by key
    const alloc = gc.allocator;
    const keys_arr = try alloc.alloc(Value, items.len);
    defer alloc.free(keys_arr);
    for (items, 0..) |item, i| {
        var a = [_]Value{item};
        keys_arr[i] = try eval_mod.apply(keyfn, &a, env, gc);
    }
    // Simple insertion sort (stable) using precomputed keys
    const out = obj.data.vector.items.items;
    var i: usize = 1;
    while (i < out.len) : (i += 1) {
        const ki = keys_arr[i];
        const vi = out[i];
        var j: usize = i;
        while (j > 0 and valueLessThanSimple(ki, keys_arr[j - 1], gc)) : (j -= 1) {
            out[j] = out[j - 1];
            keys_arr[j] = keys_arr[j - 1];
        }
        out[j] = vi;
        keys_arr[j] = ki;
    }
    return Value.makeObj(obj);
}

fn valueLessThan(gc: *GC, a: Value, b: Value) bool {
    return valueLessThanSimple(a, b, gc);
}

fn valueLessThanSimple(a: Value, b: Value, gc: *GC) bool {
    if (a.isInt() and b.isInt()) return a.asInt() < b.asInt();
    if (a.isFloat() and b.isFloat()) return a.asFloat() < b.asFloat();
    if (a.isInt() and b.isFloat()) return @as(f64, @floatFromInt(a.asInt())) < b.asFloat();
    if (a.isFloat() and b.isInt()) return a.asFloat() < @as(f64, @floatFromInt(b.asInt()));
    if (a.isString() and b.isString()) {
        return std.mem.order(u8, gc.getString(a.asStringId()), gc.getString(b.asStringId())) == .lt;
    }
    if (a.isKeyword() and b.isKeyword()) {
        return std.mem.order(u8, gc.getString(a.asKeywordId()), gc.getString(b.asKeywordId())) == .lt;
    }
    return false;
}

fn distinctFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = try seqItems(args[0], gc);
    const obj = try gc.allocObj(.vector);
    for (items) |item| {
        var dup = false;
        for (obj.data.vector.items.items) |existing| {
            if (semantics.structuralEq(item, existing, gc)) { dup = true; break; }
        }
        if (!dup) try obj.data.vector.items.append(gc.allocator, item);
    }
    return Value.makeObj(obj);
}

fn flattenFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const obj = try gc.allocObj(.vector);
    try flattenInto(args[0], obj, gc);
    return Value.makeObj(obj);
}

fn flattenInto(val: Value, obj: *value.Obj, gc: *GC) !void {
    if (!val.isObj()) {
        try obj.data.vector.items.append(gc.allocator, val);
        return;
    }
    const o = val.asObj();
    const items = switch (o.kind) {
        .list => o.data.list.items.items,
        .vector => o.data.vector.items.items,
        else => {
            try obj.data.vector.items.append(gc.allocator, val);
            return;
        },
    };
    for (items) |item| try flattenInto(item, obj, gc);
}

fn mapcatFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const f = args[0];
    const items = try seqItems(args[1], gc);
    const obj = try gc.allocObj(.vector);
    for (items) |item| {
        var a = [_]Value{item};
        const r = try eval_mod.apply(f, &a, env, gc);
        if (r.isObj()) {
            const ro = r.asObj();
            const sub_items = switch (ro.kind) {
                .list => ro.data.list.items.items,
                .vector => ro.data.vector.items.items,
                else => &[_]Value{r},
            };
            try obj.data.vector.items.appendSlice(gc.allocator, sub_items);
        } else if (!r.isNil()) {
            try obj.data.vector.items.append(gc.allocator, r);
        }
    }
    return Value.makeObj(obj);
}

fn interleaveFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    var seqs: [8][]Value = undefined;
    var min_len: usize = std.math.maxInt(usize);
    const n = @min(args.len, 8);
    for (0..n) |i| {
        seqs[i] = try seqItems(args[i], gc);
        min_len = @min(min_len, seqs[i].len);
    }
    const obj = try gc.allocObj(.vector);
    for (0..min_len) |j| {
        for (0..n) |i| {
            try obj.data.vector.items.append(gc.allocator, seqs[i][j]);
        }
    }
    return Value.makeObj(obj);
}

fn interposeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const sep = args[0];
    const items = try seqItems(args[1], gc);
    const obj = try gc.allocObj(.vector);
    for (items, 0..) |item, i| {
        if (i > 0) try obj.data.vector.items.append(gc.allocator, sep);
        try obj.data.vector.items.append(gc.allocator, item);
    }
    return Value.makeObj(obj);
}

fn partitionFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const n: usize = std.math.cast(usize, @max(@as(i48, 1), args[0].asInt())) orelse 1;
    const items = try seqItems(args[1], gc);
    const obj = try gc.allocObj(.vector);
    var i: usize = 0;
    while (i + n <= items.len) : (i += n) {
        const chunk = try gc.allocObj(.vector);
        try chunk.data.vector.items.appendSlice(gc.allocator, items[i .. i + n]);
        try obj.data.vector.items.append(gc.allocator, Value.makeObj(chunk));
    }
    return Value.makeObj(obj);
}

fn frequenciesFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = try seqItems(args[0], gc);
    const obj = try gc.allocObj(.map);
    for (items) |item| {
        var found = false;
        for (obj.data.map.keys.items, 0..) |k, i| {
            if (semantics.structuralEq(k, item, gc)) {
                const old = obj.data.map.vals.items[i].asInt();
                obj.data.map.vals.items[i] = Value.makeInt(old + 1);
                found = true;
                break;
            }
        }
        if (!found) {
            try obj.data.map.keys.append(gc.allocator, item);
            try obj.data.map.vals.append(gc.allocator, Value.makeInt(1));
        }
    }
    return Value.makeObj(obj);
}

fn groupByFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const f = args[0];
    const items = try seqItems(args[1], gc);
    const obj = try gc.allocObj(.map);
    for (items) |item| {
        var a = [_]Value{item};
        const key = try eval_mod.apply(f, &a, env, gc);
        var found = false;
        for (obj.data.map.keys.items, 0..) |k, i| {
            if (semantics.structuralEq(k, key, gc)) {
                const vec = obj.data.map.vals.items[i].asObj();
                try vec.data.vector.items.append(gc.allocator, item);
                found = true;
                break;
            }
        }
        if (!found) {
            try obj.data.map.keys.append(gc.allocator, key);
            const vec = try gc.allocObj(.vector);
            try vec.data.vector.items.append(gc.allocator, item);
            try obj.data.map.vals.append(gc.allocator, Value.makeObj(vec));
        }
    }
    return Value.makeObj(obj);
}

// ============================================================================
// TYPE OPS
// ============================================================================

fn nameFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isString()) return args[0];
    if (args[0].isKeyword()) return Value.makeString(args[0].asKeywordId());
    if (args[0].isSymbol()) return Value.makeString(args[0].asSymbolId());
    _ = gc;
    return error.TypeError;
}

fn keywordFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isKeyword()) return args[0];
    if (args[0].isString()) return Value.makeKeyword(args[0].asStringId());
    if (args[0].isSymbol()) return Value.makeKeyword(args[0].asSymbolId());
    _ = gc;
    return error.TypeError;
}

fn symbolFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isSymbol()) return args[0];
    if (args[0].isString()) {
        const s = gc.getString(args[0].asStringId());
        return Value.makeSymbol(try gc.internString(s));
    }
    if (args[0].isKeyword()) {
        return Value.makeSymbol(args[0].asKeywordId());
    }
    return error.TypeError;
}

fn typeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const v = args[0];
    const t: []const u8 = if (v.isNil()) "nil"
    else if (v.isBool()) "boolean"
    else if (v.isInt()) "integer"
    else if (v.isFloat()) "float"
    else if (v.isString()) "string"
    else if (v.isKeyword()) "keyword"
    else if (v.isSymbol()) "symbol"
    else if (v.isObj()) switch (v.asObj().kind) {
        .list => "list",
        .vector => "vector",
        .map => "map",
        .set => "set",
        .function => "function",
        .macro_fn => "macro",
        .atom => "atom",
        .bc_closure => "function",
        .builtin_ref => "function",
        .lazy_seq => "lazy-seq",
        .partial_fn => "function",
        .multimethod => "multimethod",
        .protocol => "protocol",
        .dense_f64 => "dense-f64",
        .trace => "trace",
        .rational => "rational",
        .color => "color",
        .channel => "channel",
    }
    else "unknown";
    return Value.makeString(try gc.internString(t));
}

fn identityFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return args[0];
}

// ============================================================================
// ATOM / REFERENCE TYPES
// ============================================================================

fn atomFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const obj = try gc.allocObj(.atom);
    obj.data.atom.val = args[0];
    return Value.makeObj(obj);
}

/// Polymorphic perception: deref any IDeref-able reference type.
/// atom → current value, lazy_seq/delay → cached or force, volatile → value
fn derefFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    return switch (obj.kind) {
        .atom => obj.data.atom.val,
        .lazy_seq => if (obj.data.lazy_seq.cached) |c| c else Value.makeNil(),
        .dense_f64 => args[0], // dense vectors are their own percept
        .trace => args[0], // traces are their own percept
        else => error.TypeError,
    };
}

fn swapFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    if (obj.kind != .atom) return error.TypeError;
    const old = obj.data.atom.val;
    var call_args_buf: [8]Value = undefined;
    call_args_buf[0] = old;
    const extra = args[2..];
    const n = @min(extra.len, 7);
    for (0..n) |i| call_args_buf[1 + i] = extra[i];
    const new_val = try eval_mod.apply(args[1], call_args_buf[0 .. 1 + n], env, gc);
    obj.data.atom.val = new_val;
    return new_val;
}

fn resetFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    if (obj.kind != .atom) return error.TypeError;
    obj.data.atom.val = args[1];
    return args[1];
}

fn compareAndSetFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    if (obj.kind != .atom) return error.TypeError;
    if (semantics.structuralEq(obj.data.atom.val, args[1], gc)) {
        obj.data.atom.val = args[2];
        return Value.makeBool(true);
    }
    return Value.makeBool(false);
}

// ============================================================================
// I/O
// ============================================================================

fn cFopen(path: []const u8, mode: [*c]const u8) ?*std.c.FILE {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return null;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    return std.c.fopen(@ptrCast(&pbuf), mode);
}

fn slurpFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    const path = gc.getString(args[0].asStringId());
    const cf = cFopen(path, "r") orelse return Value.makeNil();
    defer _ = std.c.fclose(cf);
    var contents = compat.emptyList(u8);
    defer contents.deinit(gc.allocator);
    var rbuf: [4096]u8 = undefined;
    while (true) {
        const rn = std.c.fread(&rbuf, 1, rbuf.len, cf);
        if (rn == 0) break;
        try contents.appendSlice(gc.allocator, rbuf[0..rn]);
    }
    return Value.makeString(try gc.internString(contents.items));
}

fn spitFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    const path = gc.getString(args[0].asStringId());
    const data = if (args[1].isString()) gc.getString(args[1].asStringId()) else blk: {
        var pbuf = compat.emptyList(u8);
        defer pbuf.deinit(gc.allocator);
        try printer.prStrInto(&pbuf, args[1], gc, false);
        break :blk try gc.allocator.dupe(u8, pbuf.items);
    };
    const cf = cFopen(path, "w") orelse return Value.makeNil();
    defer _ = std.c.fclose(cf);
    _ = std.c.fwrite(data.ptr, 1, data.len, cf);
    return Value.makeNil();
}

fn readLineFn(_: []Value, gc: *GC, _: *Env) anyerror!Value {
    const stdin = compat.stdinFile();
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = compat.fileRead(stdin, buf[len .. len + 1]);
        if (n == 0) break;
        if (buf[len] == '\n') break;
        len += 1;
    }
    if (len == 0) return Value.makeNil();
    return Value.makeString(try gc.internString(buf[0..len]));
}

extern "c" fn popen(command: [*c]const u8, mode: [*c]const u8) ?*std.c.FILE;
extern "c" fn pclose(stream: *std.c.FILE) c_int;

/// (shell cmd) → {:out "stdout" :exit code} — execute shell command via popen
/// (sh cmd) — alias
fn shellFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    const cmd = gc.getString(args[0].asStringId());
    // Null-terminate for C
    var cbuf: [8192]u8 = undefined;
    if (cmd.len >= cbuf.len) return error.ValueError;
    @memcpy(cbuf[0..cmd.len], cmd);
    cbuf[cmd.len] = 0;
    const pipe = popen(@ptrCast(&cbuf), "r") orelse return Value.makeNil();
    // Read all stdout
    var out = compat.emptyList(u8);
    defer out.deinit(gc.allocator);
    var rbuf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&rbuf, 1, rbuf.len, pipe);
        if (n == 0) break;
        try out.appendSlice(gc.allocator, rbuf[0..n]);
    }
    const status = pclose(pipe);
    const exit_code: i48 = @intCast(@as(i32, @intCast(status)) >> 8);
    // Build result map {:out "..." :exit code}
    const result_obj = try gc.allocObj(.map);
    try result_obj.data.map.keys.append(gc.allocator, Value.makeString(try gc.internString("out")));
    try result_obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(out.items)));
    try result_obj.data.map.keys.append(gc.allocator, Value.makeString(try gc.internString("exit")));
    try result_obj.data.map.vals.append(gc.allocator, Value.makeInt(exit_code));
    return Value.makeObj(result_obj);
}

// ============================================================================
// MATH EXTRAS
// ============================================================================

fn absFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isInt()) return Value.makeInt(if (args[0].asInt() < 0) -args[0].asInt() else args[0].asInt());
    if (args[0].isFloat()) return Value.makeFloat(@abs(args[0].asFloat()));
    return error.TypeError;
}

fn minFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    var best = args[0];
    for (args[1..]) |a| {
        if (numLt(a, best)) best = a;
    }
    return best;
}

fn maxFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    var best = args[0];
    for (args[1..]) |a| {
        if (numLt(best, a)) best = a;
    }
    return best;
}

fn numLt(a: Value, b: Value) bool {
    if (a.isInt() and b.isInt()) return a.asInt() < b.asInt();
    const fa: f64 = if (a.isInt()) @floatFromInt(a.asInt()) else if (a.isFloat()) a.asFloat() else return false;
    const fb: f64 = if (b.isInt()) @floatFromInt(b.asInt()) else if (b.isFloat()) b.asFloat() else return false;
    return fa < fb;
}

var rand_state: u64 = 42;

fn randFn(_: []Value, _: *GC, _: *Env) anyerror!Value {
    const r = substrate.splitmix_next(rand_state);
    rand_state = r.next;
    const f: f64 = @as(f64, @floatFromInt(r.val >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    return Value.makeFloat(f);
}

fn randIntFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.TypeError;
    const n = args[0].asInt();
    if (n <= 0) return error.ArityError;
    const r = substrate.splitmix_next(rand_state);
    rand_state = r.next;
    return Value.makeInt(@rem(@as(i48, @truncate(@as(i64, @bitCast(r.val)))), n));
}

// ============================================================================
// BITWISE
// ============================================================================

fn bitAndFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.TypeError;
    return Value.makeInt(args[0].asInt() & args[1].asInt());
}

fn bitOrFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.TypeError;
    return Value.makeInt(args[0].asInt() | args[1].asInt());
}

fn bitXorFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.TypeError;
    return Value.makeInt(args[0].asInt() ^ args[1].asInt());
}

fn bitShiftLeftFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const shift: u6 = std.math.cast(u6, @max(@as(i48, 0), args[1].asInt())) orelse return error.ArityError;
    return Value.makeInt(args[0].asInt() << shift);
}

fn bitShiftRightFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const shift: u6 = std.math.cast(u6, @max(@as(i48, 0), args[1].asInt())) orelse return error.ArityError;
    return Value.makeInt(args[0].asInt() >> shift);
}

// ============================================================================
// STRING EXTRAS (SIMD-backed)
// ============================================================================

fn reFindFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isString() or !args[1].isString()) return error.TypeError;
    const pat_str = gc.getString(args[0].asStringId());
    const text = gc.getString(args[1].asStringId());
    const re = regex.Regex.init(pat_str);
    const result = re.find(text) orelse return Value.makeNil();
    return Value.makeString(try gc.internString(result));
}

fn countStrFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isString() or !args[1].isString()) return error.TypeError;
    const s = gc.getString(args[0].asStringId());
    const needle = gc.getString(args[1].asStringId());
    return Value.makeInt(@intCast(simd_str.countSubstring(s, needle)));
}

// ============================================================================
// HELPERS
// ============================================================================

fn seqItems(val: Value, gc: *GC) ![]Value {
    _ = gc;
    if (val.isNil()) return &[_]Value{};
    if (!val.isObj()) return error.TypeError;
    const obj = val.asObj();
    return switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        else => error.TypeError,
    };
}

// ============================================================================
// PATTERN MATCHING BUILTINS
// ============================================================================

fn matchResultToValue(r: pat_mod.MatchResult, gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("matched?")));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(r.matched));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("consumed")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.consumed)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("trit")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@as(i48, r.trit)));
    return Value.makeObj(obj);
}

/// (re-match engine pattern input) → {:matched? bool :consumed N :trit T}
fn reMatchFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 3) return error.ArityError;
    if (!args[0].isKeyword() or !args[1].isString() or !args[2].isString()) return error.TypeError;
    const engine_name = gc.getString(args[0].asKeywordId());
    const pat = gc.getString(args[1].asStringId());
    const input = gc.getString(args[2].asStringId());
    const engine: pat_mod.Engine = if (std.mem.eql(u8, engine_name, "thompson")) .thompson
        else if (std.mem.eql(u8, engine_name, "derivative")) .derivative
        else if (std.mem.eql(u8, engine_name, "backtrack")) .backtrack
        else return error.TypeError;
    return matchResultToValue(pat_mod.matchWith(engine, pat, input), gc);
}

/// (peg-match engine pattern input) → {:matched? bool :consumed N :trit T}
fn pegMatchFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 3) return error.ArityError;
    if (!args[0].isKeyword() or !args[1].isString() or !args[2].isString()) return error.TypeError;
    const engine_name = gc.getString(args[0].asKeywordId());
    const pat = gc.getString(args[1].asStringId());
    const input = gc.getString(args[2].asStringId());
    const engine: pat_mod.Engine = if (std.mem.eql(u8, engine_name, "recursive")) .peg_rd
        else if (std.mem.eql(u8, engine_name, "packrat")) .peg_packrat
        else if (std.mem.eql(u8, engine_name, "vm")) .peg_vm
        else return error.TypeError;
    return matchResultToValue(pat_mod.matchWith(engine, pat, input), gc);
}

/// (match-all pattern input) → vector of 6 results, one per engine
fn matchAllFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isString() or !args[1].isString()) return error.TypeError;
    const pat = gc.getString(args[0].asStringId());
    const input = gc.getString(args[1].asStringId());
    const engines = [_]pat_mod.Engine{ .thompson, .derivative, .backtrack, .peg_rd, .peg_packrat, .peg_vm };
    const names = [_][]const u8{ "thompson", "derivative", "backtrack", "peg-rd", "peg-packrat", "peg-vm" };
    const obj = try gc.allocObj(.vector);
    for (engines, names) |e, name| {
        const r = pat_mod.matchWith(e, pat, input);
        const entry = try gc.allocObj(.map);
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("engine")));
        try entry.data.map.vals.append(gc.allocator, Value.makeKeyword(try gc.internString(name)));
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("matched?")));
        try entry.data.map.vals.append(gc.allocator, Value.makeBool(r.matched));
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("consumed")));
        try entry.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.consumed)));
        try obj.data.vector.items.append(gc.allocator, Value.makeObj(entry));
    }
    return Value.makeObj(obj);
}

// ============================================================================
// HOF COMBINATORS (using partial_fn ObjKind)
// ============================================================================

fn partialFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const obj = try gc.allocObj(.partial_fn);
    obj.data.partial_fn.func = args[0];
    for (args[1..]) |a| {
        try obj.data.partial_fn.bound_args.append(gc.allocator, a);
    }
    return Value.makeObj(obj);
}

fn compFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    if (args.len == 1) return args[0];
    const obj = try gc.allocObj(.partial_fn);
    obj.data.partial_fn.func = Value.makeNil(); // sentinel for comp
    const marker = Value.makeKeyword(try gc.internString("__comp__"));
    try obj.data.partial_fn.bound_args.append(gc.allocator, marker);
    for (args) |a| try obj.data.partial_fn.bound_args.append(gc.allocator, a);
    return Value.makeObj(obj);
}

fn juxtFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    const obj = try gc.allocObj(.partial_fn);
    obj.data.partial_fn.func = Value.makeNil();
    const marker = Value.makeKeyword(try gc.internString("__juxt__"));
    try obj.data.partial_fn.bound_args.append(gc.allocator, marker);
    for (args) |a| try obj.data.partial_fn.bound_args.append(gc.allocator, a);
    return Value.makeObj(obj);
}

fn complementFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const obj = try gc.allocObj(.partial_fn);
    obj.data.partial_fn.func = Value.makeNil();
    const marker = Value.makeKeyword(try gc.internString("__complement__"));
    try obj.data.partial_fn.bound_args.append(gc.allocator, marker);
    try obj.data.partial_fn.bound_args.append(gc.allocator, args[0]);
    return Value.makeObj(obj);
}

fn constantlyFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const obj = try gc.allocObj(.partial_fn);
    obj.data.partial_fn.func = Value.makeNil();
    const marker = Value.makeKeyword(try gc.internString("__constantly__"));
    try obj.data.partial_fn.bound_args.append(gc.allocator, marker);
    try obj.data.partial_fn.bound_args.append(gc.allocator, args[0]);
    return Value.makeObj(obj);
}

// ============================================================================
// LAZY SEQUENCES
// ============================================================================

fn iterateFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const obj = try gc.allocObj(.lazy_seq);
    const payload = try gc.allocObj(.vector);
    const marker = Value.makeKeyword(try gc.internString("__iterate__"));
    try payload.data.vector.items.append(gc.allocator, marker);
    try payload.data.vector.items.append(gc.allocator, args[0]);
    try payload.data.vector.items.append(gc.allocator, args[1]);
    obj.data.lazy_seq.thunk = Value.makeObj(payload);
    return Value.makeObj(obj);
}

fn repeatFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 and args.len != 2) return error.ArityError;
    const obj = try gc.allocObj(.lazy_seq);
    const payload = try gc.allocObj(.vector);
    const marker = Value.makeKeyword(try gc.internString("__repeat__"));
    try payload.data.vector.items.append(gc.allocator, marker);
    try payload.data.vector.items.append(gc.allocator, args[0]);
    if (args.len == 2) try payload.data.vector.items.append(gc.allocator, args[1]);
    obj.data.lazy_seq.thunk = Value.makeObj(payload);
    return Value.makeObj(obj);
}

fn repeatedlyFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const obj = try gc.allocObj(.lazy_seq);
    const payload = try gc.allocObj(.vector);
    const marker = Value.makeKeyword(try gc.internString("__repeatedly__"));
    try payload.data.vector.items.append(gc.allocator, marker);
    try payload.data.vector.items.append(gc.allocator, args[0]);
    obj.data.lazy_seq.thunk = Value.makeObj(payload);
    return Value.makeObj(obj);
}

fn lazySeqFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const obj = try gc.allocObj(.lazy_seq);
    obj.data.lazy_seq.thunk = args[0];
    return Value.makeObj(obj);
}

fn realizedFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj()) return Value.makeBool(true);
    if (args[0].asObj().kind != .lazy_seq) return Value.makeBool(true);
    return Value.makeBool(args[0].asObj().data.lazy_seq.cached != null);
}

// ============================================================================
// ADDITIONAL SEQUENCE OPS
// ============================================================================

fn takeWhileFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const f = args[0];
    const items = try seqItems(args[1], gc);
    const obj = try gc.allocObj(.vector);
    for (items) |item| {
        var a = [_]Value{item};
        const r = try eval_mod.apply(f, &a, env, gc);
        if (!r.isTruthy()) break;
        try obj.data.vector.items.append(gc.allocator, item);
    }
    return Value.makeObj(obj);
}

fn dropWhileFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const f = args[0];
    const items = try seqItems(args[1], gc);
    const obj = try gc.allocObj(.vector);
    var dropping = true;
    for (items) |item| {
        if (dropping) {
            var a = [_]Value{item};
            const r = try eval_mod.apply(f, &a, env, gc);
            if (!r.isTruthy()) dropping = false;
        }
        if (!dropping) try obj.data.vector.items.append(gc.allocator, item);
    }
    return Value.makeObj(obj);
}

fn zipmapFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const keys = try seqItems(args[0], gc);
    const vals = try seqItems(args[1], gc);
    const obj = try gc.allocObj(.map);
    const n = @min(keys.len, vals.len);
    for (0..n) |i| {
        try obj.data.map.keys.append(gc.allocator, keys[i]);
        try obj.data.map.vals.append(gc.allocator, vals[i]);
    }
    return Value.makeObj(obj);
}

// ============================================================================
// ADDITIONAL PREDICATES
// ============================================================================

fn isIntegerP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isInt());
}

fn isFloatP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isFloat());
}

fn isPosP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isInt()) return Value.makeBool(args[0].asInt() > 0);
    if (args[0].isFloat()) return Value.makeBool(args[0].asFloat() > 0);
    return error.TypeError;
}

fn isNegP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isInt()) return Value.makeBool(args[0].asInt() < 0);
    if (args[0].isFloat()) return Value.makeBool(args[0].asFloat() < 0);
    return error.TypeError;
}

fn isEvenP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.TypeError;
    return Value.makeBool(@rem(args[0].asInt(), 2) == 0);
}

fn isOddP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.TypeError;
    return Value.makeBool(@rem(args[0].asInt(), 2) != 0);
}

// ============================================================================
// TEST FRAMEWORK BUILTINS
// ============================================================================

/// (is expr) — assert expr is truthy; reports pass/fail
fn isFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const val = args[0];
    const stderr = compat.stderrFile();
    if (val.isTruthy()) {
        eval_mod.test_pass_count += 1;
        return Value.makeBool(true);
    } else {
        eval_mod.test_fail_count += 1;
        compat.fileWriteAll(stderr, "FAIL");
        if (eval_mod.current_test_name.len > 0) {
            compat.fileWriteAll(stderr, " in ");
            compat.fileWriteAll(stderr, eval_mod.current_test_name);
        }
        if (eval_mod.current_testing_label.len > 0) {
            compat.fileWriteAll(stderr, " \"");
            compat.fileWriteAll(stderr, eval_mod.current_testing_label);
            compat.fileWriteAll(stderr, "\"");
        }
        compat.fileWriteAll(stderr, ": expected truthy, got ");
        var buf = compat.emptyList(u8);
        defer buf.deinit(gc.allocator);
        try printer.prStrInto(&buf, val, gc, true);
        compat.fileWriteAll(stderr, buf.items);
        compat.fileWriteAll(stderr, "\n");
        return Value.makeBool(false);
    }
}

/// (is= expected actual) — assert structural equality
fn isEqualFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const stderr = compat.stderrFile();
    if (semantics.structuralEq(args[0], args[1], gc)) {
        eval_mod.test_pass_count += 1;
        return Value.makeBool(true);
    } else {
        eval_mod.test_fail_count += 1;
        compat.fileWriteAll(stderr, "FAIL");
        if (eval_mod.current_test_name.len > 0) {
            compat.fileWriteAll(stderr, " in ");
            compat.fileWriteAll(stderr, eval_mod.current_test_name);
        }
        compat.fileWriteAll(stderr, ": expected ");
        var buf = compat.emptyList(u8);
        defer buf.deinit(gc.allocator);
        try printer.prStrInto(&buf, args[0], gc, true);
        compat.fileWriteAll(stderr, buf.items);
        compat.fileWriteAll(stderr, ", got ");
        buf.items.len = 0;
        try printer.prStrInto(&buf, args[1], gc, true);
        compat.fileWriteAll(stderr, buf.items);
        compat.fileWriteAll(stderr, "\n");
        return Value.makeBool(false);
    }
}

/// (run-tests) — print summary and return {:pass N :fail N}
fn runTestsFn(_: []Value, gc: *GC, _: *Env) anyerror!Value {
    const counts = eval_mod.getTestCounts();
    const stderr = compat.stderrFile();
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "\nRan tests: {d} passed, {d} failed\n", .{ counts.pass, counts.fail }) catch "?";
    compat.fileWriteAll(stderr, msg);
    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("pass")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(counts.pass)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("fail")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(counts.fail)));
    eval_mod.resetTestCounts();
    return Value.makeObj(obj);
}

// ============================================================================
// NAMESPACE BUILTINS
// ============================================================================

fn currentNsFn(_: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (eval_mod.ns_registry) |reg| {
        return Value.makeSymbol(try gc.internString(reg.currentName()));
    }
    return Value.makeSymbol(try gc.internString("user"));
}

fn nsNameFn(_: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (eval_mod.ns_registry) |reg| {
        return Value.makeString(try gc.internString(reg.currentName()));
    }
    return Value.makeString(try gc.internString("user"));
}

fn allNsFn(_: []Value, gc: *GC, _: *Env) anyerror!Value {
    const obj = try gc.allocObj(.vector);
    if (eval_mod.ns_registry) |reg| {
        var it = reg.namespaces.keyIterator();
        while (it.next()) |key| {
            try obj.data.vector.items.append(gc.allocator, Value.makeSymbol(try gc.internString(key.*)));
        }
    }
    return Value.makeObj(obj);
}

/// (require [ns :as alias]) — load namespace and alias it
/// Simplified: just creates the alias mapping
fn requireFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    var reg = eval_mod.ns_registry orelse return Value.makeNil();
    for (args) |arg| {
        if (!arg.isObj()) continue;
        const a = arg.asObj();
        if (a.kind != .vector) continue;
        const items = a.data.vector.items.items;
        if (items.len == 0) continue;
        // [ns-name :as alias]
        const ns_name = if (items[0].isSymbol())
            gc.getString(items[0].asSymbolId())
        else
            continue;
        // Create the namespace if it doesn't exist
        _ = reg.switchTo(ns_name) catch continue;
        // Switch back to current
        _ = reg.switchTo(reg.current) catch {};
        // Handle :as alias
        if (items.len >= 3 and items[1].isKeyword()) {
            const directive = gc.getString(items[1].asKeywordId());
            if (std.mem.eql(u8, directive, "as") and items[2].isSymbol()) {
                const alias_name = gc.getString(items[2].asSymbolId());
                reg.addAlias(reg.current, ns_name, alias_name) catch {};
            } else if (std.mem.eql(u8, directive, "refer") and items[2].isKeyword()) {
                const refer_type = gc.getString(items[2].asKeywordId());
                if (std.mem.eql(u8, refer_type, "all")) {
                    reg.refer(reg.current, ns_name) catch {};
                }
            }
        }
    }
    return Value.makeNil();
}

// ============================================================================
// COLORSPACE BUILTINS
// ============================================================================

const colorspace_mod = @import("colorspace.zig");

fn makeColorValue(color: colorspace_mod.Color, gc: *GC) !Value {
    const obj = try gc.allocObj(.color);
    obj.data = .{ .color = color };
    return Value.makeObj(obj);
}

/// Legacy compat — still available but prefer makeColorValue
fn colorToVector(color: colorspace_mod.Color, gc: *GC) !Value {
    return makeColorValue(color, gc);
}

/// (*cs*) — return current colorspace name as symbol
fn currentCsFn(_: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (eval_mod.cs_registry) |reg| {
        return Value.makeSymbol(try gc.internString(reg.currentName()));
    }
    return Value.makeSymbol(try gc.internString("user"));
}

/// (cs-color) or (cs-color name) — return [L a b alpha] of current or named colorspace
fn csColorFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const reg = eval_mod.cs_registry orelse return Value.makeNil();
    if (args.len == 0) {
        return colorToVector(reg.currentColor(), gc);
    }
    if (args[0].isSymbol() or args[0].isKeyword()) {
        const name = if (args[0].isSymbol()) gc.getString(args[0].asSymbolId()) else gc.getString(args[0].asKeywordId());
        if (reg.getSpace(name)) |sp| {
            return colorToVector(sp.color, gc);
        }
    }
    return Value.makeNil();
}

/// (cs-complement) — return [L a b alpha] of perceptual complement of current focus
fn csComplementFn(_: []Value, gc: *GC, _: *Env) anyerror!Value {
    const reg = eval_mod.cs_registry orelse return Value.makeNil();
    return colorToVector(reg.currentColor().complement(), gc);
}

/// (cs-distance name1 name2) — perceptual distance between two colorspaces
fn csDistanceFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const reg = eval_mod.cs_registry orelse return Value.makeNil();
    const n1 = if (args[0].isSymbol()) gc.getString(args[0].asSymbolId()) else if (args[0].isKeyword()) gc.getString(args[0].asKeywordId()) else return error.TypeError;
    const n2 = if (args[1].isSymbol()) gc.getString(args[1].asSymbolId()) else if (args[1].isKeyword()) gc.getString(args[1].asKeywordId()) else return error.TypeError;
    const s1 = reg.getSpace(n1) orelse return Value.makeNil();
    const s2 = reg.getSpace(n2) orelse return Value.makeNil();
    return Value.makeFloat(s1.color.distance(s2.color));
}

/// (cs-hue) or (cs-hue name) — hue angle in degrees [0, 360)
fn csHueFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const reg = eval_mod.cs_registry orelse return Value.makeNil();
    if (args.len == 0) return Value.makeFloat(reg.currentColor().hue());
    if (args[0].isSymbol() or args[0].isKeyword()) {
        const name = if (args[0].isSymbol()) gc.getString(args[0].asSymbolId()) else gc.getString(args[0].asKeywordId());
        if (reg.getSpace(name)) |sp| return Value.makeFloat(sp.color.hue());
    }
    return Value.makeNil();
}

/// (cs-chroma) or (cs-chroma name) — chroma (saturation) magnitude
fn csChromaFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const reg = eval_mod.cs_registry orelse return Value.makeNil();
    if (args.len == 0) return Value.makeFloat(reg.currentColor().chroma());
    if (args[0].isSymbol() or args[0].isKeyword()) {
        const name = if (args[0].isSymbol()) gc.getString(args[0].asSymbolId()) else gc.getString(args[0].asKeywordId());
        if (reg.getSpace(name)) |sp| return Value.makeFloat(sp.color.chroma());
    }
    return Value.makeNil();
}

/// (cs-resolve sym) — resolve symbol through color manifold (nearest colorspace with binding)
fn csResolveFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const reg = eval_mod.cs_registry orelse return Value.makeNil();
    const name = if (args[0].isSymbol()) gc.getString(args[0].asSymbolId()) else if (args[0].isString()) gc.getString(args[0].asStringId()) else return error.TypeError;
    return reg.resolve(name) orelse Value.makeNil();
}

/// (cs-radius) or (cs-radius new-radius) — get or set resolution radius
fn csRadiusFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (eval_mod.cs_registry) |*reg| {
        if (args.len == 0) return Value.makeFloat(reg.radius);
        if (args.len == 1) {
            const r = if (args[0].isFloat()) @as(f32, @floatCast(args[0].asFloat())) else if (args[0].isInt()) @as(f32, @floatFromInt(args[0].asInt())) else return error.TypeError;
            reg.radius = r;
            return Value.makeFloat(r);
        }
    }
    return Value.makeNil();
}

// ============================================================================
// FIRST-CLASS COLOR BUILTINS
// ============================================================================

fn asColor(v: Value) ?colorspace_mod.Color {
    if (!v.isObj()) return null;
    const obj = v.asObj();
    if (obj.kind != .color) return null;
    return obj.data.color;
}

fn toF32(v: Value) ?f32 {
    if (v.isFloat()) return @floatCast(v.asFloat());
    if (v.isInt()) return @floatFromInt(v.asInt());
    return null;
}

/// (color L a b) or (color L a b alpha) — construct a first-class OKLAB color
fn colorCtorFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 3) return error.ArityError;
    const L = toF32(args[0]) orelse return error.TypeError;
    const a = toF32(args[1]) orelse return error.TypeError;
    const b = toF32(args[2]) orelse return error.TypeError;
    const alpha = if (args.len > 3) (toF32(args[3]) orelse return error.TypeError) else @as(f32, 1.0);
    return makeColorValue(.{ .L = L, .a = a, .b = b, .alpha = alpha }, gc);
}

/// (color? x) — true if x is a first-class color value
fn colorPredFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(asColor(args[0]) != null);
}

/// (color-blend c1 c2 t) — perceptual blend in OKLAB
fn colorBlendFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const c1 = asColor(args[0]) orelse return error.TypeError;
    const c2 = asColor(args[1]) orelse return error.TypeError;
    const t = toF32(args[2]) orelse return error.TypeError;
    return makeColorValue(c1.blend(c2, t), gc);
}

/// (color-complement c) — 180° rotation in a-b plane + lightness inversion
fn colorComplementFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const c = asColor(args[0]) orelse return error.TypeError;
    return makeColorValue(c.complement(), gc);
}

/// (color-analogous c angle-deg) — rotate in a-b chroma plane
fn colorAnalogousFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const c = asColor(args[0]) orelse return error.TypeError;
    const angle = toF32(args[1]) orelse return error.TypeError;
    return makeColorValue(c.analogous(angle), gc);
}

/// (color-triadic c) — [c c+120° c+240°]
fn colorTriadicFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const c = asColor(args[0]) orelse return error.TypeError;
    const tri = c.triadic();
    const obj = try gc.allocObj(.vector);
    for (tri) |tc| {
        try obj.data.vector.items.append(gc.allocator, try makeColorValue(tc, gc));
    }
    return Value.makeObj(obj);
}

/// (color-distance c1 c2) — Euclidean distance in OKLAB (≈ perceptual JND)
fn colorDistanceFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const c1 = asColor(args[0]) orelse return error.TypeError;
    const c2 = asColor(args[1]) orelse return error.TypeError;
    return Value.makeFloat(c1.distance(c2));
}

/// (color-hue c) — hue angle in degrees [0,360)
fn colorHueFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const c = asColor(args[0]) orelse return error.TypeError;
    return Value.makeFloat(c.hue());
}

/// (color-chroma c) — chroma magnitude
fn colorChromaFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const c = asColor(args[0]) orelse return error.TypeError;
    return Value.makeFloat(c.chroma());
}

/// (color-L c), (color-a c), (color-b c), (color-alpha c) — accessors
fn colorLFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const c = asColor(args[0]) orelse return error.TypeError;
    return Value.makeFloat(c.L);
}
fn colorAFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const c = asColor(args[0]) orelse return error.TypeError;
    return Value.makeFloat(c.a);
}
fn colorBFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const c = asColor(args[0]) orelse return error.TypeError;
    return Value.makeFloat(c.b);
}
fn colorAlphaFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const c = asColor(args[0]) orelse return error.TypeError;
    return Value.makeFloat(c.alpha);
}

// ============================================================================
// REGEX BUILTINS
// ============================================================================

/// (re-pattern str) — identity: pattern is the string itself
fn rePatternFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    return args[0];
}

/// (re-matches pattern string) — match entire string, return match or nil
fn reMatchesFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isString() or !args[1].isString()) return error.TypeError;
    const pat_str = gc.getString(args[0].asStringId());
    const text = gc.getString(args[1].asStringId());
    const re = regex.Regex.init(pat_str);
    return if (re.matches(text)) args[1] else Value.makeNil();
}

/// (re-seq pattern text) — return list of all non-overlapping matches
fn reSeqFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isString() or !args[1].isString()) return error.TypeError;
    const pat_str = gc.getString(args[0].asStringId());
    const text = gc.getString(args[1].asStringId());
    const re = regex.Regex.init(pat_str);
    const matches = re.findAll(text, gc.allocator) catch return error.OutOfMemory;
    defer gc.allocator.free(matches);
    const result = try gc.allocObj(.list);
    for (matches) |m| {
        const id = try gc.internString(m);
        try result.data.list.items.append(gc.allocator, Value.makeString(id));
    }
    return Value.makeObj(result);
}

// ============================================================================
// NESTED MAP OPS
// ============================================================================

/// (get-in m [k1 k2 ...]) — nested lookup
fn getInFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    var current = args[0];
    const keys = try seqItems(args[1], gc);
    for (keys) |k| {
        if (!current.isObj()) return if (args.len > 2) args[2] else Value.makeNil();
        const obj = current.asObj();
        if (obj.kind == .map) {
            var found = false;
            for (obj.data.map.keys.items, 0..) |mk, i| {
                if (semantics.structuralEq(mk, k, gc)) {
                    current = obj.data.map.vals.items[i];
                    found = true;
                    break;
                }
            }
            if (!found) return if (args.len > 2) args[2] else Value.makeNil();
        } else if (obj.kind == .vector) {
            if (k.isInt()) {
                const idx: usize = @intCast(k.asInt());
                if (idx < obj.data.vector.items.items.len) {
                    current = obj.data.vector.items.items[idx];
                } else return if (args.len > 2) args[2] else Value.makeNil();
            } else return if (args.len > 2) args[2] else Value.makeNil();
        } else return if (args.len > 2) args[2] else Value.makeNil();
    }
    return current;
}

/// (assoc-in m [k1 k2 ...] v) — nested assoc
fn assocInFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const keys = try seqItems(args[1], gc);
    if (keys.len == 0) return args[0];
    if (keys.len == 1) {
        // Base case: (assoc m k v)
        return assocSingle(args[0], keys[0], args[2], gc);
    }
    // Recursive: (assoc m k0 (assoc-in (get m k0) [k1..] v))
    const inner = getFromMap(args[0], keys[0], gc);
    // Build rest-keys vector
    const rest_keys_obj = try gc.allocObj(.vector);
    try rest_keys_obj.data.vector.items.appendSlice(gc.allocator, keys[1..]);
    var inner_args = [3]Value{ inner, Value.makeObj(rest_keys_obj), args[2] };
    const nested = try assocInFn(&inner_args, gc, env);
    return assocSingle(args[0], keys[0], nested, gc);
}

fn getFromMap(m: Value, k: Value, gc: *GC) Value {
    if (!m.isObj()) return Value.makeNil();
    const obj = m.asObj();
    if (obj.kind != .map) return Value.makeNil();
    for (obj.data.map.keys.items, 0..) |mk, i| {
        if (semantics.structuralEq(mk, k, gc)) return obj.data.map.vals.items[i];
    }
    return Value.makeNil();
}

fn assocSingle(m: Value, k: Value, v: Value, gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    if (m.isObj() and m.asObj().kind == .map) {
        const src = m.asObj();
        var replaced = false;
        for (src.data.map.keys.items, 0..) |mk, i| {
            if (semantics.structuralEq(mk, k, gc)) {
                try obj.data.map.keys.append(gc.allocator, mk);
                try obj.data.map.vals.append(gc.allocator, v);
                replaced = true;
            } else {
                try obj.data.map.keys.append(gc.allocator, mk);
                try obj.data.map.vals.append(gc.allocator, src.data.map.vals.items[i]);
            }
        }
        if (!replaced) {
            try obj.data.map.keys.append(gc.allocator, k);
            try obj.data.map.vals.append(gc.allocator, v);
        }
    } else {
        try obj.data.map.keys.append(gc.allocator, k);
        try obj.data.map.vals.append(gc.allocator, v);
    }
    return Value.makeObj(obj);
}

/// (update-in m [k1 k2 ...] f) — apply f to nested value
fn updateInFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 3) return error.ArityError;
    const keys = try seqItems(args[1], gc);
    if (keys.len == 0) return args[0];
    // Get the current nested value
    var get_in_args = [_]Value{ args[0], args[1] };
    const current = try getInFn(&get_in_args, gc, env);
    // Apply f to it
    var fn_args = [_]Value{current};
    const new_val = try eval_mod.apply(args[2], &fn_args, env, gc);
    // assoc-in the result
    var assoc_args = [_]Value{ args[0], args[1], new_val };
    return assocInFn(&assoc_args, gc, env);
}

/// (reduce-kv f init map) — reduce over map entries as (f acc k v)
fn reduceKvFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    if (!args[2].isObj() or args[2].asObj().kind != .map) return error.TypeError;
    const m = args[2].asObj();
    var acc = args[1];
    for (m.data.map.keys.items, 0..) |k, i| {
        var fn_args = [_]Value{ acc, k, m.data.map.vals.items[i] };
        acc = try eval_mod.apply(args[0], &fn_args, env, gc);
    }
    return acc;
}

// ============================================================================
// TRANSIENTS
// ============================================================================

/// (transient coll) — return a mutable version of the collection
fn transientFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const src = args[0].asObj();
    return switch (src.kind) {
        .vector => blk: {
            const obj = try gc.allocObj(.vector);
            obj.is_transient = true;
            try obj.data.vector.items.appendSlice(gc.allocator, src.data.vector.items.items);
            break :blk Value.makeObj(obj);
        },
        .map => blk: {
            const obj = try gc.allocObj(.map);
            obj.is_transient = true;
            try obj.data.map.keys.appendSlice(gc.allocator, src.data.map.keys.items);
            try obj.data.map.vals.appendSlice(gc.allocator, src.data.map.vals.items);
            break :blk Value.makeObj(obj);
        },
        .set => blk: {
            const obj = try gc.allocObj(.set);
            obj.is_transient = true;
            try obj.data.set.items.appendSlice(gc.allocator, src.data.set.items.items);
            break :blk Value.makeObj(obj);
        },
        else => error.TypeError,
    };
}

/// (persistent! tcoll) — return an immutable version
fn persistentBangFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    if (!obj.is_transient) return error.TypeError;
    obj.is_transient = false;
    return args[0];
}

/// (conj! tcoll val) — mutate: add val to transient collection
fn conjBangFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    if (!obj.is_transient) return error.TypeError;
    switch (obj.kind) {
        .vector => try obj.data.vector.items.append(gc.allocator, args[1]),
        .set => try obj.data.set.items.append(gc.allocator, args[1]),
        .list => try obj.data.list.items.append(gc.allocator, args[1]),
        else => return error.TypeError,
    }
    return args[0];
}

/// (assoc! tmap key val) — mutate: set key→val in transient map
fn assocBangFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    if (!obj.is_transient or obj.kind != .map) return error.TypeError;
    // Check for existing key
    for (obj.data.map.keys.items, 0..) |k, i| {
        if (semantics.structuralEq(k, args[1], gc)) {
            obj.data.map.vals.items[i] = args[2];
            return args[0];
        }
    }
    try obj.data.map.keys.append(gc.allocator, args[1]);
    try obj.data.map.vals.append(gc.allocator, args[2]);
    return args[0];
}

/// (dissoc! tmap key) — mutate: remove key from transient map
fn dissocBangFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    if (!obj.is_transient or obj.kind != .map) return error.TypeError;
    for (obj.data.map.keys.items, 0..) |k, i| {
        if (semantics.structuralEq(k, args[1], gc)) {
            _ = obj.data.map.keys.orderedRemove(i);
            _ = obj.data.map.vals.orderedRemove(i);
            return args[0];
        }
    }
    return args[0]; // key not found, no-op
}

/// (transient? x) — true if x is a transient collection
fn isTransientFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj()) return Value.makeBool(false);
    return Value.makeBool(args[0].asObj().is_transient);
}

// ============================================================================
// METADATA
// ============================================================================

/// (meta obj) — return metadata map or nil
fn metaFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj()) return Value.makeNil();
    if (args[0].asObj().meta) |m| return Value.makeObj(m);
    return Value.makeNil();
}

/// (with-meta obj meta-map) — return a copy of obj with metadata attached
fn withMetaFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const src = args[0].asObj();
    // Create a shallow copy with the same data
    const new_obj = try gc.allocObj(src.kind);
    new_obj.data = src.data;
    new_obj.is_transient = src.is_transient;
    // Attach metadata
    if (args[1].isObj() and args[1].asObj().kind == .map) {
        new_obj.meta = args[1].asObj();
    } else if (args[1].isNil()) {
        new_obj.meta = null;
    } else {
        return error.TypeError;
    }
    return Value.makeObj(new_obj);
}

/// (vary-meta obj f & args) — apply f to metadata: (with-meta obj (apply f (meta obj) args))
fn varyMetaFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const current_meta = if (args[0].asObj().meta) |m| Value.makeObj(m) else Value.makeNil();
    // Build args for f: [current-meta & extra-args]
    var fn_args_buf: [16]Value = undefined;
    fn_args_buf[0] = current_meta;
    const extra = @min(args.len - 2, 15);
    for (args[2..2 + extra], 0..) |a, i| {
        fn_args_buf[1 + i] = a;
    }
    const new_meta = try eval_mod.apply(args[1], fn_args_buf[0 .. 1 + extra], env, gc);
    // with-meta
    var wm_args = [_]Value{ args[0], new_meta };
    return withMetaFn(&wm_args, gc, env);
}

// ============================================================================
// BATCH: 30 trivial builtins for jank coverage push 39% → 55%
// ============================================================================

fn seqFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil()) return Value.makeNil();
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    return switch (obj.kind) {
        .list => if (obj.data.list.items.items.len == 0) Value.makeNil() else args[0],
        .vector => if (obj.data.vector.items.items.len == 0) Value.makeNil() else args[0],
        .set => if (obj.data.set.items.items.len == 0) Value.makeNil() else args[0],
        else => args[0],
    };
}

fn vecFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil()) return Value.makeObj(try gc.allocObj(.vector));
    if (!args[0].isObj()) return error.TypeError;
    const items = getItems(args[0]) orelse return error.TypeError;
    const obj = try gc.allocObj(.vector);
    try obj.data.vector.items.appendSlice(gc.allocator, items);
    return Value.makeObj(obj);
}

fn nextFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return Value.makeNil();
    if (items.len <= 1) return Value.makeNil();
    const obj = try gc.allocObj(.list);
    try obj.data.list.items.appendSlice(gc.allocator, items[1..]);
    return Value.makeObj(obj);
}

fn butlastFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return Value.makeNil();
    if (items.len <= 1) return Value.makeNil();
    const obj = try gc.allocObj(.list);
    try obj.data.list.items.appendSlice(gc.allocator, items[0 .. items.len - 1]);
    return Value.makeObj(obj);
}

fn ffirstFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const outer = getItems(args[0]) orelse return Value.makeNil();
    if (outer.len == 0) return Value.makeNil();
    const inner = getItems(outer[0]) orelse return Value.makeNil();
    return if (inner.len > 0) inner[0] else Value.makeNil();
}

fn fnextFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return Value.makeNil();
    if (items.len < 2) return Value.makeNil();
    return items[1];
}

fn peekFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return Value.makeNil();
    if (items.len == 0) return Value.makeNil();
    // peek: last for vector, first for list
    if (args[0].isObj() and args[0].asObj().kind == .vector) return items[items.len - 1];
    return items[0];
}

fn popFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;
    if (items.len == 0) return error.TypeError;
    if (args[0].asObj().kind == .vector) {
        const obj = try gc.allocObj(.vector);
        try obj.data.vector.items.appendSlice(gc.allocator, items[0 .. items.len - 1]);
        return Value.makeObj(obj);
    }
    const obj = try gc.allocObj(.list);
    try obj.data.list.items.appendSlice(gc.allocator, items[1..]);
    return Value.makeObj(obj);
}

fn disjFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isObj() or args[0].asObj().kind != .set) return error.TypeError;
    const items = args[0].asObj().data.set.items.items;
    const obj = try gc.allocObj(.set);
    for (items) |item| {
        var keep = true;
        for (args[1..]) |to_remove| {
            if (semantics.structuralEq(item, to_remove, gc)) { keep = false; break; }
        }
        if (keep) try obj.data.set.items.append(gc.allocator, item);
    }
    return Value.makeObj(obj);
}

fn emptyFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj()) return Value.makeNil();
    return switch (args[0].asObj().kind) {
        .list => Value.makeObj(try gc.allocObj(.list)),
        .vector => Value.makeObj(try gc.allocObj(.vector)),
        .map => Value.makeObj(try gc.allocObj(.map)),
        .set => Value.makeObj(try gc.allocObj(.set)),
        else => Value.makeNil(),
    };
}

fn notEmptyFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil()) return Value.makeNil();
    if (!args[0].isObj()) return args[0];
    const items = getItems(args[0]) orelse return args[0];
    return if (items.len == 0) Value.makeNil() else args[0];
}

fn remFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0].isInt() and args[1].isInt()) {
        if (args[1].asInt() == 0) return error.DivisionByZero;
        return Value.makeInt(@rem(args[0].asInt(), args[1].asInt()));
    }
    return error.TypeError;
}

fn quotFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0].isInt() and args[1].isInt()) {
        if (args[1].asInt() == 0) return error.DivisionByZero;
        return Value.makeInt(@divTrunc(args[0].asInt(), args[1].asInt()));
    }
    return error.TypeError;
}

fn hashFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeInt(@as(i48, @truncate(@as(i64, @bitCast(substrate.mix64(args[0].bits))))));
}

fn charFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isInt()) return Value.makeInt(args[0].asInt() & 0xFF);
    return error.TypeError;
}

fn intFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isInt()) return args[0];
    if (args[0].isFloat()) return Value.makeInt(@intFromFloat(args[0].asFloat()));
    return error.TypeError;
}

fn longFn(args: []Value, _: *GC, _: *Env) anyerror!Value { return intFn(args, undefined, undefined); }
fn doubleFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isFloat()) return args[0];
    if (args[0].isInt()) return Value.makeFloat(@floatFromInt(args[0].asInt()));
    return error.TypeError;
}
fn byteFn(args: []Value, _: *GC, _: *Env) anyerror!Value { return charFn(args, undefined, undefined); }
fn numFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return args[0]; // identity for numeric types
}

fn isTrueP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isBool() and args[0].asBool());
}
fn isFalseP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isBool() and !args[0].asBool());
}
fn isCollP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj()) return Value.makeBool(false);
    return Value.makeBool(switch (args[0].asObj().kind) {
        .list, .vector, .map, .set => true,
        else => false,
    });
}
fn isBoolP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isBool());
}
fn isCharP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(false); // nanoclj-zig has no char type
}
fn isIntP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isInt());
}
fn identicalP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return Value.makeBool(args[0].bits == args[1].bits);
}
fn compareFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0].isInt() and args[1].isInt()) {
        const a = args[0].asInt();
        const b = args[1].asInt();
        return Value.makeInt(if (a < b) @as(i48, -1) else if (a > b) @as(i48, 1) else 0);
    }
    return Value.makeInt(0);
}
fn formatFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    // Simplified: just return (str args...) for now
    if (args.len == 0) return error.ArityError;
    var buf = compat.emptyList(u8);
    for (args) |a| {
        try printer.prStrInto(&buf, a, gc, false);
    }
    const id = try gc.internString(buf.items);
    buf.deinit(gc.allocator);
    return Value.makeString(id);
}

// ============================================================================
// BATCH 2: 57 builtins for 69% jank coverage
// ============================================================================

fn notEqFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return Value.makeBool(!semantics.structuralEq(args[0], args[1], gc));
}
fn anyP(args: []Value, _: *GC, _: *Env) anyerror!Value { _ = args; return Value.makeBool(true); }
fn someP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(!args[0].isNil());
}
fn nanP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isFloat() and std.math.isNan(args[0].asFloat()));
}
fn isDoubleP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isFloat());
}
fn seqableP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil() or args[0].isString()) return Value.makeBool(true);
    if (!args[0].isObj()) return Value.makeBool(false);
    return Value.makeBool(switch (args[0].asObj().kind) { .list, .vector, .map, .set => true, else => false });
}
fn countedP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj()) return Value.makeBool(false);
    return Value.makeBool(switch (args[0].asObj().kind) { .list, .vector, .map, .set => true, else => false });
}
fn associativeP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj()) return Value.makeBool(false);
    return Value.makeBool(switch (args[0].asObj().kind) { .map, .vector => true, else => false });
}
fn identP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isKeyword() or args[0].isSymbol());
}
fn ifnP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isKeyword()) return Value.makeBool(true);
    if (!args[0].isObj()) return Value.makeBool(false);
    return Value.makeBool(switch (args[0].asObj().kind) { .function, .bc_closure, .builtin_ref, .partial_fn => true, else => false });
}
fn qualIdentP(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isKeyword()) return Value.makeBool(std.mem.indexOf(u8, gc.getString(args[0].asKeywordId()), "/") != null);
    if (args[0].isSymbol()) return Value.makeBool(std.mem.indexOf(u8, gc.getString(args[0].asSymbolId()), "/") != null);
    return Value.makeBool(false);
}
fn qualKeywordP(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isKeyword()) return Value.makeBool(false);
    return Value.makeBool(std.mem.indexOf(u8, gc.getString(args[0].asKeywordId()), "/") != null);
}
fn qualSymbolP(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isSymbol()) return Value.makeBool(false);
    return Value.makeBool(std.mem.indexOf(u8, gc.getString(args[0].asSymbolId()), "/") != null);
}
fn simpleIdentP(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isKeyword()) return Value.makeBool(std.mem.indexOf(u8, gc.getString(args[0].asKeywordId()), "/") == null);
    if (args[0].isSymbol()) return Value.makeBool(std.mem.indexOf(u8, gc.getString(args[0].asSymbolId()), "/") == null);
    return Value.makeBool(false);
}
fn simpleKeywordP(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isKeyword()) return Value.makeBool(false);
    return Value.makeBool(std.mem.indexOf(u8, gc.getString(args[0].asKeywordId()), "/") == null);
}
fn simpleSymbolP(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isSymbol()) return Value.makeBool(false);
    return Value.makeBool(std.mem.indexOf(u8, gc.getString(args[0].asSymbolId()), "/") == null);
}
fn negIntP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isInt() and args[0].asInt() < 0);
}
fn posIntP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isInt() and args[0].asInt() > 0);
}
fn natIntP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isInt() and args[0].asInt() >= 0);
}
fn specialSymbolP(_: []Value, _: *GC, _: *Env) anyerror!Value { return Value.makeBool(false); }
fn varP(_: []Value, _: *GC, _: *Env) anyerror!Value { return Value.makeBool(false); }
fn ratioP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .rational);
}
fn rationalP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isInt() or (args[0].isObj() and args[0].asObj().kind == .rational));
}
fn decimalP(_: []Value, _: *GC, _: *Env) anyerror!Value { return Value.makeBool(false); }
fn uuidP(_: []Value, _: *GC, _: *Env) anyerror!Value { return Value.makeBool(false); }
fn reversibleP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isObj()) return Value.makeBool(false);
    return Value.makeBool(args[0].asObj().kind == .vector);
}
fn sortedP(_: []Value, _: *GC, _: *Env) anyerror!Value { return Value.makeBool(false); }
fn nfirstFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    var a = [_]Value{args[0]}; const n = try nextFn(&a, gc, env);
    if (n.isNil()) return Value.makeNil();
    var b = [_]Value{n}; return first(&b, gc, env);
}
fn nnextFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    var a = [_]Value{args[0]}; const n = try nextFn(&a, gc, env);
    if (n.isNil()) return Value.makeNil();
    var b = [_]Value{n}; return nextFn(&b, gc, env);
}
fn nthnextFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2 or !args[1].isInt()) return error.ArityError;
    var cur = args[0]; var n = args[1].asInt();
    while (n > 0) : (n -= 1) { var a = [_]Value{cur}; cur = try nextFn(&a, gc, env); if (cur.isNil()) return Value.makeNil(); }
    return cur;
}
fn nthrestFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[1].isInt()) return error.ArityError;
    const items = getItems(args[0]) orelse return Value.makeObj(try gc.allocObj(.list));
    const n: usize = @intCast(@max(@as(i48, 0), args[1].asInt()));
    const obj = try gc.allocObj(.list);
    if (n < items.len) try obj.data.list.items.appendSlice(gc.allocator, items[n..]);
    return Value.makeObj(obj);
}
fn findFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isObj() or args[0].asObj().kind != .map) return Value.makeNil();
    for (args[0].asObj().data.map.keys.items, args[0].asObj().data.map.vals.items) |k, v| {
        if (semantics.structuralEq(k, args[1], gc)) {
            const p = try gc.allocObj(.vector);
            try p.data.vector.items.append(gc.allocator, k);
            try p.data.vector.items.append(gc.allocator, v);
            return Value.makeObj(p);
        }
    }
    return Value.makeNil();
}
fn keyFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return Value.makeNil();
    return if (items.len > 0) items[0] else Value.makeNil();
}
fn valFn2(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return Value.makeNil();
    return if (items.len > 1) items[1] else Value.makeNil();
}
fn subvecFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2 or !args[1].isInt()) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;
    const start: usize = @intCast(@max(@as(i48, 0), args[1].asInt()));
    const end: usize = if (args.len > 2 and args[2].isInt()) @intCast(@max(@as(i48, 0), args[2].asInt())) else items.len;
    const obj = try gc.allocObj(.vector);
    try obj.data.vector.items.appendSlice(gc.allocator, items[@min(start, items.len)..@min(end, items.len)]);
    return Value.makeObj(obj);
}
fn takeLastFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt()) return error.ArityError;
    const n: usize = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const items = getItems(args[1]) orelse return Value.makeObj(try gc.allocObj(.list));
    const start = if (n >= items.len) 0 else items.len - n;
    const obj = try gc.allocObj(.list);
    try obj.data.list.items.appendSlice(gc.allocator, items[start..]);
    return Value.makeObj(obj);
}
fn takeNthFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt()) return error.ArityError;
    const n: usize = @intCast(@max(@as(i48, 1), args[0].asInt()));
    const items = getItems(args[1]) orelse return Value.makeObj(try gc.allocObj(.vector));
    const obj = try gc.allocObj(.vector);
    var i: usize = 0;
    while (i < items.len) : (i += n) try obj.data.vector.items.append(gc.allocator, items[i]);
    return Value.makeObj(obj);
}
fn dropLastFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const n: usize = if (args.len > 1 and args[0].isInt()) @intCast(@max(@as(i48, 0), args[0].asInt())) else 1;
    const coll = if (args.len > 1) args[1] else args[0];
    const items = getItems(coll) orelse return Value.makeObj(try gc.allocObj(.list));
    const end = if (n >= items.len) 0 else items.len - n;
    const obj = try gc.allocObj(.list);
    try obj.data.list.items.appendSlice(gc.allocator, items[0..end]);
    return Value.makeObj(obj);
}
fn cycleFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return Value.makeObj(try gc.allocObj(.list));
    if (items.len == 0) return Value.makeObj(try gc.allocObj(.list));
    const obj = try gc.allocObj(.list);
    var i: usize = 0;
    while (i < 100) : (i += 1) try obj.data.list.items.append(gc.allocator, items[i % items.len]);
    return Value.makeObj(obj);
}
fn shuffleFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;
    const obj = try gc.allocObj(.vector);
    try obj.data.vector.items.appendSlice(gc.allocator, items);
    var state = substrate.mix64(@as(u64, items.len));
    var sl = obj.data.vector.items.items;
    var i = sl.len;
    while (i > 1) { i -= 1; const r = substrate.splitmix_next(state); state = r.next;
        const j = r.val % (i + 1); const tmp = sl[i]; sl[i] = sl[j]; sl[j] = tmp; }
    return Value.makeObj(obj);
}
fn randNthFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return Value.makeNil();
    if (items.len == 0) return Value.makeNil();
    const r = substrate.splitmix_next(rand_state); rand_state = r.next;
    return items[r.val % items.len];
}
fn minKeyFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    var best = args[1];
    for (args[2..]) |v| {
        var ba = [_]Value{best}; var va = [_]Value{v};
        const bk = try eval_mod.apply(args[0], &ba, env, gc);
        const vk = try eval_mod.apply(args[0], &va, env, gc);
        if (vk.isInt() and bk.isInt() and vk.asInt() < bk.asInt()) best = v;
    }
    return best;
}
fn maxKeyFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    var best = args[1];
    for (args[2..]) |v| {
        var ba = [_]Value{best}; var va = [_]Value{v};
        const bk = try eval_mod.apply(args[0], &ba, env, gc);
        const vk = try eval_mod.apply(args[0], &va, env, gc);
        if (bk.isInt() and vk.isInt() and bk.asInt() < vk.asInt()) best = v;
    }
    return best;
}
fn someFnFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    const obj = try gc.allocObj(.partial_fn);
    obj.data.partial_fn.func = Value.makeNil();
    try obj.data.partial_fn.bound_args.append(gc.allocator, Value.makeKeyword(try gc.internString("__some-fn__")));
    for (args) |a| try obj.data.partial_fn.bound_args.append(gc.allocator, a);
    return Value.makeObj(obj);
}
fn fnilFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const obj = try gc.allocObj(.partial_fn);
    obj.data.partial_fn.func = Value.makeNil();
    try obj.data.partial_fn.bound_args.append(gc.allocator, Value.makeKeyword(try gc.internString("__fnil__")));
    for (args) |a| try obj.data.partial_fn.bound_args.append(gc.allocator, a);
    return Value.makeObj(obj);
}
fn hashSetFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const obj = try gc.allocObj(.set);
    for (args) |a| try obj.data.set.items.append(gc.allocator, a);
    return Value.makeObj(obj);
}
fn namespaceFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const s = if (args[0].isKeyword()) gc.getString(args[0].asKeywordId()) else if (args[0].isSymbol()) gc.getString(args[0].asSymbolId()) else return Value.makeNil();
    if (std.mem.indexOf(u8, s, "/")) |idx| return Value.makeString(try gc.internString(s[0..idx]));
    return Value.makeNil();
}
fn parseLongFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return Value.makeNil();
    return Value.makeInt(std.fmt.parseInt(i48, gc.getString(args[0].asStringId()), 10) catch return Value.makeNil());
}
fn parseDoubleFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return Value.makeNil();
    return Value.makeFloat(std.fmt.parseFloat(f64, gc.getString(args[0].asStringId())) catch return Value.makeNil());
}
fn parseBooleanFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return Value.makeNil();
    const s = gc.getString(args[0].asStringId());
    return if (std.mem.eql(u8, s, "true")) Value.makeBool(true) else if (std.mem.eql(u8, s, "false")) Value.makeBool(false) else Value.makeNil();
}
fn bitNotFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.TypeError;
    return Value.makeInt(~args[0].asInt());
}
fn bitTestFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const bit: u6 = @intCast(@max(@as(i48, 0), @min(args[1].asInt(), 47)));
    return Value.makeBool((args[0].asInt() & (@as(i48, 1) << bit)) != 0);
}
fn bitSetFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const bit: u6 = @intCast(@max(@as(i48, 0), @min(args[1].asInt(), 47)));
    return Value.makeInt(args[0].asInt() | (@as(i48, 1) << bit));
}
fn bitClearFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const bit: u6 = @intCast(@max(@as(i48, 0), @min(args[1].asInt(), 47)));
    return Value.makeInt(args[0].asInt() & ~(@as(i48, 1) << bit));
}
fn bitFlipFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const bit: u6 = @intCast(@max(@as(i48, 0), @min(args[1].asInt(), 47)));
    return Value.makeInt(args[0].asInt() ^ (@as(i48, 1) << bit));
}
fn bitAndNotFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.TypeError;
    return Value.makeInt(args[0].asInt() & ~args[1].asInt());
}
fn unsignedBitShiftRightFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const n: u48 = @bitCast(args[0].asInt());
    const shift: u6 = @intCast(@max(@as(i48, 0), @min(args[1].asInt(), 47)));
    return Value.makeInt(@bitCast(n >> shift));
}

// ============================================================================
// SEQUENCE OPS: mapv, filterv, remove, keep, map-indexed, keep-indexed
// ============================================================================

fn mapvFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const items = getItems(args[1]) orelse return error.TypeError;
    const obj = try gc.allocObj(.vector);
    for (items) |item| {
        var a = [_]Value{item};
        const r = try eval_mod.apply(args[0], &a, env, gc);
        try obj.data.vector.items.append(gc.allocator, r);
    }
    return Value.makeObj(obj);
}

fn filtervFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const items = getItems(args[1]) orelse return error.TypeError;
    const obj = try gc.allocObj(.vector);
    for (items) |item| {
        var a = [_]Value{item};
        const r = try eval_mod.apply(args[0], &a, env, gc);
        if (r.isTruthy()) try obj.data.vector.items.append(gc.allocator, item);
    }
    return Value.makeObj(obj);
}

fn removeFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const items = getItems(args[1]) orelse return error.TypeError;
    const obj = try gc.allocObj(.list);
    for (items) |item| {
        var a = [_]Value{item};
        const r = try eval_mod.apply(args[0], &a, env, gc);
        if (!r.isTruthy()) try obj.data.list.items.append(gc.allocator, item);
    }
    return Value.makeObj(obj);
}

fn keepFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const items = getItems(args[1]) orelse return error.TypeError;
    const obj = try gc.allocObj(.list);
    for (items) |item| {
        var a = [_]Value{item};
        const r = try eval_mod.apply(args[0], &a, env, gc);
        if (!r.isNil()) try obj.data.list.items.append(gc.allocator, r);
    }
    return Value.makeObj(obj);
}

fn keepIndexedFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const items = getItems(args[1]) orelse return error.TypeError;
    const obj = try gc.allocObj(.list);
    for (items, 0..) |item, i| {
        var a = [_]Value{ Value.makeInt(@intCast(i)), item };
        const r = try eval_mod.apply(args[0], &a, env, gc);
        if (!r.isNil()) try obj.data.list.items.append(gc.allocator, r);
    }
    return Value.makeObj(obj);
}

fn mapIndexedFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const items = getItems(args[1]) orelse return error.TypeError;
    const obj = try gc.allocObj(.list);
    for (items, 0..) |item, i| {
        var a = [_]Value{ Value.makeInt(@intCast(i)), item };
        const r = try eval_mod.apply(args[0], &a, env, gc);
        try obj.data.list.items.append(gc.allocator, r);
    }
    return Value.makeObj(obj);
}

// ============================================================================
// I/O: print, pr, prn
// ============================================================================

fn printFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const stdout = compat.stdoutFile();
    for (args, 0..) |arg, i| {
        if (i > 0) compat.fileWriteAll(stdout, " ");
        if (arg.isString()) {
            compat.fileWriteAll(stdout, gc.getString(arg.asStringId()));
        } else {
            var buf = compat.emptyList(u8);
            defer buf.deinit(gc.allocator);
            try printer.prStrInto(&buf, arg, gc, false);
            compat.fileWriteAll(stdout, buf.items);
        }
    }
    return Value.makeNil();
}

fn prFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const stdout = compat.stdoutFile();
    for (args, 0..) |arg, i| {
        if (i > 0) compat.fileWriteAll(stdout, " ");
        var buf = compat.emptyList(u8);
        defer buf.deinit(gc.allocator);
        try printer.prStrInto(&buf, arg, gc, true);
        compat.fileWriteAll(stdout, buf.items);
    }
    return Value.makeNil();
}

fn prnFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    _ = try prFn(args, gc, env);
    const stdout = compat.stdoutFile();
    compat.fileWriteAll(stdout, "\n");
    return Value.makeNil();
}

fn newlineFn(_: []Value, _: *GC, _: *Env) anyerror!Value {
    const stdout = compat.stdoutFile();
    compat.fileWriteAll(stdout, "\n");
    return Value.makeNil();
}

// ============================================================================
// VOLATILE (lightweight mutable box, no watches/validators)
// ============================================================================

/// (volatile! val) — create a volatile mutable ref (uses atom internally)
fn volatileBangFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const obj = try gc.allocObj(.atom);
    obj.data.atom.val = args[0];
    return Value.makeObj(obj);
}

/// (vswap! vol f & args) — apply f to volatile's value, store result
fn vswapBangFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isObj() or args[0].asObj().kind != .atom) return error.TypeError;
    const vol = args[0].asObj();
    var fn_args_buf: [16]Value = undefined;
    fn_args_buf[0] = vol.data.atom.val;
    const extra = @min(args.len - 2, 15);
    for (args[2..2 + extra], 0..) |a, i| fn_args_buf[1 + i] = a;
    const new_val = try eval_mod.apply(args[1], fn_args_buf[0 .. 1 + extra], env, gc);
    vol.data.atom.val = new_val;
    return new_val;
}

/// (vreset! vol val) — reset volatile to new value
fn vresetBangFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isObj() or args[0].asObj().kind != .atom) return error.TypeError;
    args[0].asObj().data.atom.val = args[1];
    return args[1];
}

// ============================================================================
// REDUCTIONS / TRANSDUCE
// ============================================================================

/// (reductions f init coll) — lazy list of intermediate reduce values
fn reductionsFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const f = args[0];
    var acc: Value = undefined;
    var items: []Value = undefined;
    if (args.len == 2) {
        // (reductions f coll) — init = (f)
        items = getItems(args[1]) orelse return error.TypeError;
        if (items.len == 0) {
            var empty_args = [_]Value{};
            acc = try eval_mod.apply(f, &empty_args, env, gc);
            const obj = try gc.allocObj(.list);
            try obj.data.list.items.append(gc.allocator, acc);
            return Value.makeObj(obj);
        }
        acc = items[0];
        items = items[1..];
    } else {
        acc = args[1];
        items = getItems(args[2]) orelse return error.TypeError;
    }
    const obj = try gc.allocObj(.list);
    try obj.data.list.items.append(gc.allocator, acc);
    for (items) |item| {
        var fn_args = [_]Value{ acc, item };
        acc = try eval_mod.apply(f, &fn_args, env, gc);
        // Check for reduced
        if (acc.isObj() and acc.asObj().kind == .vector) {
            if (acc.asObj().is_transient) { // reduced marker
                acc = acc.asObj().data.vector.items.items[0];
                try obj.data.list.items.append(gc.allocator, acc);
                break;
            }
        }
        try obj.data.list.items.append(gc.allocator, acc);
    }
    return Value.makeObj(obj);
}

/// (reduced x) — wrap x to signal early termination
fn reducedFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const obj = try gc.allocObj(.vector);
    obj.is_transient = true; // marker for "reduced"
    try obj.data.vector.items.append(gc.allocator, args[0]);
    return Value.makeObj(obj);
}

fn isReducedP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj()) return Value.makeBool(false);
    const obj = args[0].asObj();
    return Value.makeBool(obj.kind == .vector and obj.is_transient and obj.data.vector.items.items.len == 1);
}

fn unreducedFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isObj()) {
        const obj = args[0].asObj();
        if (obj.kind == .vector and obj.is_transient and obj.data.vector.items.items.len == 1)
            return obj.data.vector.items.items[0];
    }
    return args[0];
}

/// (transduce xform f init coll) — transduce with transducer
fn transduceFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 3) return error.ArityError;
    if (args.len == 3) {
        // (transduce xform f coll) — no init, use (f) as init
        const f = args[1];
        var empty_args = [_]Value{};
        const init = try eval_mod.apply(f, &empty_args, env, gc);
        var new_args = [_]Value{ args[0], args[1], init, args[2] };
        return transduceFn(&new_args, gc, env);
    }
    // (transduce xform f init coll)
    // xform is a transducer: (xform f) → reducing-fn
    var xf_args = [_]Value{args[1]};
    const rf = try eval_mod.apply(args[0], &xf_args, env, gc);
    var acc = args[2];
    const items = getItems(args[3]) orelse return error.TypeError;
    for (items) |item| {
        var fn_args = [_]Value{ acc, item };
        acc = try eval_mod.apply(rf, &fn_args, env, gc);
        if (acc.isObj() and acc.asObj().kind == .vector and acc.asObj().is_transient) {
            return acc.asObj().data.vector.items.items[0];
        }
    }
    return acc;
}

// ============================================================================
// DELAY / FORCE
// ============================================================================

/// (delay expr) — wraps a value, realized on first deref
/// Since our builtins get pre-evaluated args, delay is a special case.
/// We use lazy_seq with the value already cached.
fn delayFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const obj = try gc.allocObj(.lazy_seq);
    obj.data.lazy_seq.thunk = Value.makeNil();
    obj.data.lazy_seq.cached = args[0];
    return Value.makeObj(obj);
}

/// (force x) — realize a delay
fn forceFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isObj() and args[0].asObj().kind == .lazy_seq) {
        if (args[0].asObj().data.lazy_seq.cached) |c| return c;
    }
    return args[0];
}

/// (add-watch ref key fn) — stub, returns ref
fn addWatchFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    return args[0];
}

/// (remove-watch ref key) — stub, returns ref
fn removeWatchFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return args[0];
}

// ============================================================================
// DENSE F64 (Neanderthal-compatible)
// ============================================================================

/// (fv 1.0 2.0 3.0) or (fv n) — create dense f64 vector
fn fvFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const obj = try gc.allocObj(.dense_f64);
    if (args.len == 1 and args[0].isInt()) {
        // (fv n) — zero-filled vector of length n
        const n: usize = @intCast(@max(@as(i48, 0), args[0].asInt()));
        const data = try gc.allocator.alloc(f64, n);
        @memset(data, 0);
        obj.data.dense_f64 = .{ .data = data, .len = n, .owned = true };
    } else {
        // (fv 1.0 2.0 3.0) — from literal values
        const data = try gc.allocator.alloc(f64, args.len);
        for (args, 0..) |a, i| {
            data[i] = if (a.isFloat()) a.asFloat() else if (a.isInt()) @as(f64, @floatFromInt(a.asInt())) else 0;
        }
        obj.data.dense_f64 = .{ .data = data, .len = args.len, .owned = true };
    }
    return Value.makeObj(obj);
}

/// (fv-get v i) — get element at index
fn fvGetFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isObj() or args[0].asObj().kind != .dense_f64 or !args[1].isInt()) return error.TypeError;
    const v = &args[0].asObj().data.dense_f64;
    const i: usize = @intCast(@max(@as(i48, 0), args[1].asInt()));
    if (i >= v.len) return error.TypeError;
    return Value.makeFloat(v.get(i));
}

/// (fv-set! v i x) — set element at index (mutating)
fn fvSetBangFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    if (!args[0].isObj() or args[0].asObj().kind != .dense_f64 or !args[1].isInt()) return error.TypeError;
    var v = &args[0].asObj().data.dense_f64;
    const i: usize = @intCast(@max(@as(i48, 0), args[1].asInt()));
    if (i >= v.len) return error.TypeError;
    const x = if (args[2].isFloat()) args[2].asFloat() else if (args[2].isInt()) @as(f64, @floatFromInt(args[2].asInt())) else return error.TypeError;
    v.set(i, x);
    return args[0];
}

/// (fv-dot a b) — dot product
fn fvDotFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isObj() or args[0].asObj().kind != .dense_f64) return error.TypeError;
    if (!args[1].isObj() or args[1].asObj().kind != .dense_f64) return error.TypeError;
    return Value.makeFloat(args[0].asObj().data.dense_f64.dot(&args[1].asObj().data.dense_f64));
}

/// (fv-norm v) — L2 norm
fn fvNormFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj() or args[0].asObj().kind != .dense_f64) return error.TypeError;
    return Value.makeFloat(args[0].asObj().data.dense_f64.norm());
}

/// (fv-axpy! alpha x y) — y += alpha * x (mutating y)
fn fvAxpyBangFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const alpha = if (args[0].isFloat()) args[0].asFloat() else if (args[0].isInt()) @as(f64, @floatFromInt(args[0].asInt())) else return error.TypeError;
    if (!args[1].isObj() or args[1].asObj().kind != .dense_f64) return error.TypeError;
    if (!args[2].isObj() or args[2].asObj().kind != .dense_f64) return error.TypeError;
    args[2].asObj().data.dense_f64.axpy(alpha, &args[1].asObj().data.dense_f64);
    return args[2];
}

/// (fv-count v) — length
fn fvCountFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj() or args[0].asObj().kind != .dense_f64) return error.TypeError;
    return Value.makeInt(@intCast(args[0].asObj().data.dense_f64.len));
}

// ============================================================================
// TRACE (Anglican-compatible probabilistic programming)
// ============================================================================

/// (make-trace) — create an empty execution trace
fn makeTraceFn(_: []Value, gc: *GC, _: *Env) anyerror!Value {
    const obj = try gc.allocObj(.trace);
    obj.data.trace = .{
        .site_names = compat.emptyList(u32),
        .site_values = compat.emptyList(Value),
        .site_log_probs = compat.emptyList(f64),
    };
    return Value.makeObj(obj);
}

/// (trace-observe! trace name value log-prob) — record a sample site
fn traceObserveBangFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 4) return error.ArityError;
    if (!args[0].isObj() or args[0].asObj().kind != .trace) return error.TypeError;
    const name_id: u32 = if (args[1].isString()) @as(u32, @truncate(args[1].asStringId())) else if (args[1].isSymbol()) @as(u32, @truncate(args[1].asSymbolId())) else return error.TypeError;
    const lp = if (args[3].isFloat()) args[3].asFloat() else if (args[3].isInt()) @as(f64, @floatFromInt(args[3].asInt())) else return error.TypeError;
    try args[0].asObj().data.trace.observe(gc.allocator, name_id, args[2], lp);
    return args[0];
}

/// (trace-log-weight trace) — cumulative log-weight
fn traceLogWeightFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj() or args[0].asObj().kind != .trace) return error.TypeError;
    return Value.makeFloat(args[0].asObj().data.trace.log_weight);
}

/// (trace-sites trace) — return [{:name n :value v :log-prob lp} ...]
fn traceSitesFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj() or args[0].asObj().kind != .trace) return error.TypeError;
    const t = &args[0].asObj().data.trace;
    const result = try gc.allocObj(.vector);
    for (0..t.len()) |i| {
        const site = try gc.allocObj(.map);
        try site.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("name")));
        try site.data.map.vals.append(gc.allocator, Value.makeString(t.site_names.items[i]));
        try site.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("value")));
        try site.data.map.vals.append(gc.allocator, t.site_values.items[i]);
        try site.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("log-prob")));
        try site.data.map.vals.append(gc.allocator, Value.makeFloat(t.site_log_probs.items[i]));
        try result.data.vector.items.append(gc.allocator, Value.makeObj(site));
    }
    return Value.makeObj(result);
}

// ============================================================================
// RATIONAL NUMBERS (exact arithmetic)
// ============================================================================

/// (rational n d) — create a normalized rational number
fn rationalFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const num: i64 = args[0].asInt();
    const den: i64 = args[1].asInt();
    if (den == 0) return error.DivisionByZero;
    const obj = try gc.allocObj(.rational);
    obj.data.rational = value.Rational.init(num, den);
    return Value.makeObj(obj);
}

/// (numerator r) — get numerator of a rational
fn numeratorFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isInt()) return args[0]; // integer numerator is itself
    if (!args[0].isObj() or args[0].asObj().kind != .rational) return error.TypeError;
    return Value.makeInt(@intCast(args[0].asObj().data.rational.numerator));
}

/// (denominator r) — get denominator of a rational
fn denominatorFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isInt()) return Value.makeInt(1); // integer denominator is 1
    if (!args[0].isObj() or args[0].asObj().kind != .rational) return error.TypeError;
    return Value.makeInt(@intCast(args[0].asObj().data.rational.denominator));
}

/// (rationalize x) — convert a float to its nearest rational approximation
/// Uses continued fraction expansion (Stern-Brocot mediant convergence).
fn rationalizeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    // If already rational or integer, return as-is
    if (args[0].isInt()) return args[0];
    if (args[0].isObj() and args[0].asObj().kind == .rational) return args[0];
    if (!args[0].isFloat()) return error.TypeError;
    const x = args[0].asFloat();
    if (std.math.isNan(x) or std.math.isInf(x)) return error.TypeError;

    // Continued fraction convergents with tolerance 1e-10
    const tolerance: f64 = 1e-10;
    var p0: i64 = 0;
    var q0: i64 = 1;
    var p1: i64 = 1;
    var q1: i64 = 0;
    var val = x;
    const negative = x < 0;
    if (negative) val = -val;

    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        const a: i64 = @intFromFloat(val);
        const p2 = a * p1 + p0;
        const q2 = a * q1 + q0;
        if (q2 > 1_000_000_000) break; // prevent overflow
        p0 = p1;
        q0 = q1;
        p1 = p2;
        q1 = q2;
        const approx = @as(f64, @floatFromInt(p1)) / @as(f64, @floatFromInt(q1));
        if (@abs(approx - val) < tolerance) break;
        const rem = val - @as(f64, @floatFromInt(a));
        if (@abs(rem) < tolerance) break;
        val = 1.0 / rem;
    }

    const num = if (negative) -p1 else p1;
    const den = q1;
    if (den == 1) return Value.makeInt(@intCast(num));
    const obj = try gc.allocObj(.rational);
    obj.data.rational = value.Rational.init(num, den);
    return Value.makeObj(obj);
}

/// (rational? x) — true if x is a rational object
fn isRationalObjP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .rational);
}

