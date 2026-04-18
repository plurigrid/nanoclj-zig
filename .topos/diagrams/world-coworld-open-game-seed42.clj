;; world-coworld-open-game-seed42.clj
;;
;; A seeded `.topos` diagram artifact for the first closed open-game
;; profile. This keeps using the raw monoidal kernel directly so it stays
;; valid as a substrate-level artifact even now that explicit
;; `open-game-*` builtins are available.

(def seed 42)

(def world-coworld-open-game
  (diagram-seq
    (diagram-box
      "bootstrap-context"
      [[:ctx :x]]
      [[:ctx :world :x] [:ctx :coworld :x]]
      {:layer :contextad
       :effect-class :readonly
       :seed seed})
    (diagram-tensor
      (diagram-box
        "world-play"
        [[:ctx :world :x]]
        [[:ctx :world :y]]
        {:semantics :open-game
         :role :world
         :variance :covariant
         :seed seed})
      (diagram-box
        "coworld-coplay"
        [[:ctx :coworld :x]]
        [[:ctx :coworld :r]]
        {:semantics :open-game
         :role :coworld
         :variance :contravariant
         :seed seed}))
    (diagram-box
      "close-world"
      [[:ctx :world :y] [:ctx :coworld :r]]
      [[:ctx :closed :payoff-trace]]
      {:semantics :closure
       :agreement-required true
       :seed seed})))

(println (diagram-summary world-coworld-open-game))
(println (play world-coworld-open-game))
(println (evaluate world-coworld-open-game))
