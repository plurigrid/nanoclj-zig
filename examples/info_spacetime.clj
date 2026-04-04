(def emc2
  (fn (nodes prime)
    (let (d (causal-depth prime nodes))
      (let (vol (cone-volume prime d))
        (let (density (info-density nodes vol))
          (let (rate (/ (* 1000 vol) nodes))
            (list :prime prime :depth d :density density :rate rate
                  :product (* density rate))))))))

(def prices (list 100 105 98 110 103 107 99 112 108 115))
(def n (count prices))

(emc2 n 2)
(emc2 n 3)
(emc2 n 5)
(emc2 n 7)
(emc2 n 1069)

(emc2 333 2)
(emc2 333 3)
(emc2 333 1069)

(padic-cones (causal-depth 3 n))
(separation n (cone-volume 3 (causal-depth 3 n)))
(cognitive-jerk 333 1069)
(p-adic-depth 333)
