(def a (->> (list 1 2 3 4 5) (filter odd?)))
(def b (filter odd? (list 1 2 3 4 5)))
(def c (= a b))
(list a b c)
