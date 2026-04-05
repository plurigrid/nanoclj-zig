{:name "passport-horse"
 :description "Bridge between plurigrid.horse BCI sheaf descent and passport.gay trit-trajectory identity. Structured decompositions as shared spine: brain signals decompose into bags, trit trajectories are presheaves on session shape, bisimulation oracle verifies gluing."
 :trit -1}
---

# Passport-Horse Bridge

## When to use
Use this skill when:
- Verifying that a BCI session identity (passport.gay) is consistent with brain signal decomposition (plurigrid.horse)
- Checking behavioral equivalence of agents across protocol boundaries via bisimulation
- Designing capability-secure BCI pipelines where identity = trit trajectory = sheaf section

## The Triangle

### plurigrid.horse: Brain → Sheaf
\transclude{bci-0003}

The BCI factory decomposes brain signals via structured decompositions:
- **Bags** = electrode site neighborhoods (8-ch Cyton → overlapping patches)
- **Adhesions** = shared channels between adjacent patches
- **Sheaf** = per-patch spectral features that must glue across adhesions
- **Descent** = global brain state from local patch solutions

GF(3) encoding: HbO(+1), HbR(-1), baseline(0). Beer-Lambert is linear → trit parity conserved.

### passport.gay: Trit Trajectory → Identity
The session identity is a **presheaf on the session timeline**:
- Each epoch (200ms window) maps to a trit (+1/0/-1) via Shannon entropy thresholding
- The trajectory T: [0..N]^op → GF(3) is a presheaf on the discrete category of epochs
- Restriction maps: subsequence extraction (any sub-trajectory is still valid)
- Conservation: Σ trits ≡ 0 (mod 3) over any valid proof window

### nanoclj-zig: The Compositional Glue

```clojure
;; Decompose a BCI montage into bags
(def montage {:nodes [:Fp1 :Fp2 :C3 :C4 :O1 :O2 :A1 :A2]
              :edges [[:Fp1 :Fp2] [:C3 :C4] [:O1 :O2]
                      [:Fp1 :C3] [:Fp2 :C4] [:C3 :O1] [:C4 :O2]]})
(def bci-decomp (decompose montage))

;; Sheaf: per-patch spectral features
(def spectral-sheaf
  (sheaf
    (fn [bag] (map fft-bands bag))        ;; stalk: bag → spectral features
    (fn [sa sb adh] (coherent? sa sb adh)))) ;; glue: check phase coherence

;; Decide: can local spectra glue to global brain state?
(decomp-decide spectral-sheaf bci-decomp)  ;; → true if coherent

;; Passport: trit trajectory from entropy
(def trajectory (map entropy-to-trit epochs))
(assert (zero? (mod (reduce + trajectory) 3)))  ;; GF(3) conservation

;; Bisimulation: does the BCI decomposition produce the same
;; trit trajectory as the passport claims?
;; This is exactly decomp-decide with the passport sheaf.
```

## The Bumpus Connection

Bumpus's theorem: any problem encodable as a sheaf on a structured decomposition
is decidable in FPT time parameterized by treewidth.

For BCI: the "problem" is identity verification. The "decomposition" is the electrode
montage. The "sheaf" checks that local entropy trajectories glue to the claimed
passport trajectory. Treewidth of the 8-channel montage ≤ 3, so verification is O(n).

## Transclusion Sources
\transclude{rosetta-stone-interactive-quantitative-semantics}
\transclude{gf3-conservation}
\transclude{thy-0001}

## Builtins Used
- `(decompose graph)` — montage → inet of electrode-site bags
- `(decomp-decide sheaf net-id)` — verify local→global coherence
- `(sheaf stalk glue)` — spectral features + phase coherence
- `(section sheaf open-set)` — evaluate per-patch features
- `(restrict section subset)` — restrict to electrode subset
- `(skill-transclude id)` — pull horse/passport theory on demand
