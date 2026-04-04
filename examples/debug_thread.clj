(def a (->> 1 (+ 2)))
(def b (->> (list 1 2 3) (map inc)))
(def c (->> (list 1 2 3 4 5) (filter odd?)))
(list a b c)
