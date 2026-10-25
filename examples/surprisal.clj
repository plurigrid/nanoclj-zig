;; Eight idealized oxgangs, fifteen acres each. Context includes the revision.
(def area (surprisal/model :area/v1 [15 15 15 15 15 15 15 15]))
(def carucate (surprisal/whole area))
(def virgate (surprisal/event area [0 1]))
(def oxgang (surprisal/event area [0]))
(def first-step (surprisal/refine carucate virgate))
(def second-step (surprisal/refine virgate oxgang))

;; Doubling the sampling weight of the first oxgang changes the measure.
(def work (surprisal/model :work/v1 [30 15 15 15 15 15 15 15]))

{:area-bits (surprisal/bits oxgang)
 :first-bits (surprisal/refinement-bits first-step)
 :second-bits (surprisal/refinement-bits second-step)
 :composed-bits (surprisal/refinement-bits
                 (surprisal/compose first-step second-step))
 :work-score (surprisal/score (surprisal/event work [0]))
 :mixed-model-error (surprisal/union oxgang (surprisal/event work [0]))}
