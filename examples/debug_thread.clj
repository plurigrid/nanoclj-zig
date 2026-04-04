(println "A:" (->> (list 1 2 3 4 5) (filter odd?)))
(println "B:" (->> (list 1 2 3 4 5) (filter odd?) (map inc)))
(println "C:" (->> (list 1 2 3 4 5) (filter odd?) (map inc) (reduce + 0)))
