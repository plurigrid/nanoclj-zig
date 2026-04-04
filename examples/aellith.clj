;; Aellith phonetic parser via nanoclj-zig pattern engines
;; 9 domains × 3 voicings = 27 consonants, each carrying a GF(3) trit:
;;   approach (+1), observe (0), withdraw (-1)

;; Map consonants to their GF(3) trit (voicing)
(def consonant-trit
  (fn (c)
    (if (= c "b") 1    ;; attachment approach
    (if (= c "m") 0    ;; attachment observe
    (if (= c "p") -1   ;; attachment withdraw
    (if (= c "v") 1    ;; desire approach
    (if (= c "f") -1   ;; desire withdraw
    (if (= c "d") 1    ;; power approach
    (if (= c "n") 0    ;; power observe
    (if (= c "t") -1   ;; power withdraw
    (if (= c "g") 1    ;; jealousy approach
    (if (= c "k") -1   ;; jealousy withdraw
    (if (= c "c") -1   ;; status withdraw
    (if (= c "q") -1   ;; disgust withdraw
    (if (= c "h") 0    ;; shame observe
    0)))))))))))))))

;; Parse a simple broad transcription and compute GF(3) balance
(def parse-syllable
  (fn (s)
    (if (> (count s) 0)
      (let (c (subs s 0 1))
        (let (trit (consonant-trit c))
          (list :consonant c :trit trit :domain
            (if (= c "b") :attachment
            (if (= c "m") :attachment
            (if (= c "p") :attachment
            (if (= c "d") :power
            (if (= c "n") :power
            (if (= c "t") :power
            (if (= c "g") :jealousy
            (if (= c "k") :jealousy
            (if (= c "h") :shame
            :unknown))))))))))))
      (list :empty))))

;; Test: parse and check GF(3) conservation
(parse-syllable "b")
(parse-syllable "m")
(parse-syllable "p")

;; A balanced triple: approach + observe + withdraw = 1 + 0 + (-1) = 0
(+ (consonant-trit "b") (consonant-trit "m") (consonant-trit "p"))

;; Cross-domain: power(d) + attachment(m) + jealousy(k) = 1 + 0 + (-1) = 0
(+ (consonant-trit "d") (consonant-trit "m") (consonant-trit "k"))

;; FindBalancer confirms: given approach + observe, the balancer is withdraw
(find-balancer 1 0)

;; Pattern matching the phonemes via all 6 engines
(match-all "ba" "ba")
(re-match :thompson "b." "ba")
(peg-match :vm "b." "ba")

;; The Aellith conservation law:
;; Every well-formed experience triple sums to 0 mod 3
;; This is FindBalancer applied to phonetics
(mod (+ 1 0 -1) 3)
