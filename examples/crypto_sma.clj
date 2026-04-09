;; crypto_sma.clj — Dark terminal crypto SMA dashboard
;; BTC/ETH/SOL: live CoinGecko prices, golden/death cross detection, mini sparkline
;; Falls back to synthetic data if rate-limited.

(do

;; ═══════════════════════════════════════════════════════════════
;; ANSI escape sequences
;; ═══════════════════════════════════════════════════════════════

(def ESC "\u001b[")
(def RESET "\u001b[0m")
(def BOLD "\u001b[1m")
(def DIM "\u001b[2m")
(def BG-BLACK "\u001b[40m")
(def FG-WHITE "\u001b[97m")
(def FG-GREEN "\u001b[32m")
(def FG-RED "\u001b[31m")
(def FG-YELLOW "\u001b[33m")
(def FG-CYAN "\u001b[36m")
(def FG-MAGENTA "\u001b[35m")
(def FG-GRAY "\u001b[90m")
(def FG-BRIGHT-GREEN "\u001b[92m")
(def FG-BRIGHT-RED "\u001b[91m")
(def FG-BRIGHT-YELLOW "\u001b[93m")
(def FG-BRIGHT-CYAN "\u001b[96m")

;; ═══════════════════════════════════════════════════════════════
;; Configuration — tune SMA periods here
;; ═══════════════════════════════════════════════════════════════

(def fast-period 9)    ;; fast SMA (9-day)
(def slow-period 21)   ;; slow SMA (21-day)
(def history-days 50)  ;; days of price history to fetch
(def chart-width 40)   ;; sparkline width

;; ═══════════════════════════════════════════════════════════════
;; Sparkline blocks (8 levels)
;; ═══════════════════════════════════════════════════════════════

(def spark-chars (vector " " "\u2581" "\u2582" "\u2583" "\u2584" "\u2585" "\u2586" "\u2587" "\u2588"))

;; ═══════════════════════════════════════════════════════════════
;; Utility functions
;; ═══════════════════════════════════════════════════════════════

(defn parse-prices [raw-str]
  (if (nil? raw-str)
    nil
    (let [trimmed (trim raw-str)]
      (if (= trimmed "")
        nil
        (let [parts (split trimmed " ")]
          (map (fn [s] (read-string s)) parts))))))

(defn avg [xs]
  (if (empty? xs)
    0.0
    (/ (reduce + 0.0 xs) (count xs))))

(defn sma [prices n]
  (if (< (count prices) n)
    nil
    (let [recent (take n (reverse prices))]
      (avg recent))))

(defn sma-at [prices n offset]
  ;; SMA ending at (count - offset) position
  (if (< (count prices) (+ n offset))
    nil
    (let [end-prices (drop offset (reverse prices))
          window (take n end-prices)]
      (avg window))))

(defn round2 [x]
  (/ (int (* x 100)) 100.0))

(defn format-price [x]
  (let [rounded (round2 x)]
    (str "$" rounded)))

(defn format-pct [x]
  (let [rounded (round2 x)]
    (if (> rounded 0)
      (str "+" rounded "%")
      (str rounded "%"))))

;; ═══════════════════════════════════════════════════════════════
;; Sparkline renderer
;; ═══════════════════════════════════════════════════════════════

(defn make-sparkline [prices width color]
  (if (nil? prices)
    ""
    (let [n (count prices)
          use-n (if (> n width) width n)
          recent (if (> n width) (drop (- n width) prices) prices)
          recent-list (into [] recent)
          lo (reduce min (first recent-list) (rest recent-list))
          hi (reduce max (first recent-list) (rest recent-list))
          spread (if (= hi lo) 1.0 (- hi lo))]
      (str color
           (join "" (map (fn [p]
                           (let [norm (/ (- p lo) spread)
                                 idx (int (* norm 8))
                                 idx (if (> idx 8) 8 idx)
                                 idx (if (< idx 0) 0 idx)]
                             (nth spark-chars idx)))
                         recent-list))
           RESET))))

;; ═══════════════════════════════════════════════════════════════
;; Synthetic data generator (fallback when rate-limited)
;; ═══════════════════════════════════════════════════════════════

(defn synth-walk [start volatility n]
  (loop [prices [start]
         i 1]
    (if (>= i n)
      prices
      (let [prev (nth prices (dec i))
            pct (* volatility (- (rand) 0.48))
            next-p (* prev (+ 1.0 pct))]
        (recur (conj prices next-p) (inc i))))))

(defn make-synthetic []
  {:btc-prices (synth-walk 71000.0 0.03 history-days)
   :eth-prices (synth-walk 2200.0  0.04 history-days)
   :sol-prices (synth-walk 84.0    0.05 history-days)
   :btc-24h 0.0  :eth-24h 0.0  :sol-24h 0.0
   :synthetic true})

;; ═══════════════════════════════════════════════════════════════
;; CoinGecko data fetcher
;; ═══════════════════════════════════════════════════════════════

(defn fetch-history [coin-id]
  (let [cmd (str "curl -sf --max-time 8 'https://api.coingecko.com/api/v3/coins/"
                 coin-id
                 "/market_chart?vs_currency=usd&days=" history-days
                 "&interval=daily' | jq -r '[.prices[][1]] | map(tostring) | join(\" \")'")
        result (shell cmd)
        out (get result "out")
        exit (get result "exit")]
    (if (= exit 0)
      (parse-prices out)
      nil)))

(defn fetch-24h-change []
  (let [cmd "curl -sf --max-time 8 'https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum,solana&vs_currencies=usd&include_24hr_change=true' | jq -r '[.bitcoin.usd_24h_change, .ethereum.usd_24h_change, .solana.usd_24h_change] | map(tostring) | join(\" \")'"
        result (shell cmd)
        out (get result "out")
        exit (get result "exit")]
    (if (= exit 0)
      (parse-prices out)
      nil)))

(defn fetch-all-data []
  (let [btc (fetch-history "bitcoin")
        eth (fetch-history "ethereum")
        sol (fetch-history "solana")
        changes (fetch-24h-change)]
    (if (nil? btc)
      (make-synthetic)
      {:btc-prices (into [] btc)
       :eth-prices (if (nil? eth) (synth-walk 2200.0 0.04 history-days) (into [] eth))
       :sol-prices (if (nil? sol) (synth-walk 84.0 0.05 history-days) (into [] sol))
       :btc-24h (if (nil? changes) 0.0 (nth (into [] changes) 0))
       :eth-24h (if (nil? changes) 0.0 (nth (into [] changes) 1))
       :sol-24h (if (nil? changes) 0.0 (nth (into [] changes) 2))
       :synthetic false})))

;; ═══════════════════════════════════════════════════════════════
;; Cross detection
;; ═══════════════════════════════════════════════════════════════

(defn detect-cross [prices fast-n slow-n]
  (let [fast-now  (sma-at prices fast-n 0)
        slow-now  (sma-at prices slow-n 0)
        fast-prev (sma-at prices fast-n 1)
        slow-prev (sma-at prices slow-n 1)]
    (if (nil? fast-now)
      {:signal :insufficient :fast nil :slow nil}
      (if (nil? slow-now)
        {:signal :insufficient :fast fast-now :slow nil}
        (if (nil? fast-prev)
          {:signal :holding
           :fast fast-now :slow slow-now
           :above (> fast-now slow-now)}
          (if (nil? slow-prev)
            {:signal :holding
             :fast fast-now :slow slow-now
             :above (> fast-now slow-now)}
            ;; Both current and previous SMAs available
            (if (> fast-now slow-now)
              (if (<= fast-prev slow-prev)
                {:signal :golden-cross :fast fast-now :slow slow-now :above true}
                {:signal :bullish      :fast fast-now :slow slow-now :above true})
              (if (>= fast-prev slow-prev)
                {:signal :death-cross  :fast fast-now :slow slow-now :above false}
                {:signal :bearish      :fast fast-now :slow slow-now :above false}))))))))

;; ═══════════════════════════════════════════════════════════════
;; Display renderer
;; ═══════════════════════════════════════════════════════════════

(defn signal-str [sig]
  (let [s (get sig :signal)]
    (if (= s :golden-cross)
      (str FG-BRIGHT-GREEN BOLD ">>> GOLDEN CROSS <<<" RESET)
      (if (= s :death-cross)
        (str FG-BRIGHT-RED BOLD ">>> DEATH CROSS <<<" RESET)
        (if (= s :bullish)
          (str FG-GREEN "bullish (fast > slow)" RESET)
          (if (= s :bearish)
            (str FG-RED "bearish (fast < slow)" RESET)
            (if (= s :insufficient)
              (str FG-GRAY "insufficient data" RESET)
              (str FG-YELLOW "holding" RESET))))))))

(defn position-str [price sma-val label]
  (if (nil? sma-val)
    (str FG-GRAY "  --" RESET)
    (if (> price sma-val)
      (str FG-GREEN "  ABOVE " label RESET)
      (str FG-RED "  BELOW " label RESET))))

(defn change-str [pct]
  (if (> pct 0)
    (str FG-BRIGHT-GREEN "\u25b2 " (format-pct pct) RESET)
    (if (< pct 0)
      (str FG-BRIGHT-RED "\u25bc " (format-pct pct) RESET)
      (str FG-YELLOW "\u25c6 " (format-pct pct) RESET))))

(defn render-coin [name-str ticker color prices change-24h]
  (let [price (nth prices (dec (count prices)))
        sig (detect-cross prices fast-period slow-period)
        fast-val (get sig :fast)
        slow-val (get sig :slow)
        spark (make-sparkline prices chart-width color)]
    (println (str "  " color BOLD ticker RESET
                  "  " FG-WHITE BOLD (format-price price) RESET
                  "  " (change-str change-24h)))
    (println (str "  " FG-GRAY "SMA(" fast-period ")" RESET
                  "  " (if (nil? fast-val) "--" (format-price fast-val))
                  (position-str price fast-val (str "SMA(" fast-period ")"))))
    (println (str "  " FG-GRAY "SMA(" slow-period ")" RESET
                  "  " (if (nil? slow-val) "--" (format-price slow-val))
                  (position-str price slow-val (str "SMA(" slow-period ")"))))
    (println (str "  " FG-GRAY "Signal" RESET "  " (signal-str sig)))
    (println (str "  " spark))
    (println "")))

(defn render-header [synthetic?]
  (println "")
  (println (str FG-CYAN BOLD
               "  \u2554\u2550\u2550 CRYPTO SMA TERMINAL \u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2557"
               RESET))
  (println (str FG-GRAY
               "  \u2551  SMA(" fast-period "/" slow-period ") \u2502 "
               history-days "d history"
               (if synthetic?
                 (str " \u2502 " FG-YELLOW "SYNTHETIC" FG-GRAY)
                 (str " \u2502 " FG-GREEN "LIVE" FG-GRAY))
               "     \u2551"
               RESET))
  (println (str FG-CYAN
               "  \u2560\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2563"
               RESET))
  (println ""))

(defn render-footer []
  (println (str FG-CYAN
               "  \u255a\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u255d"
               RESET))
  (println ""))

;; ═══════════════════════════════════════════════════════════════
;; Main
;; ═══════════════════════════════════════════════════════════════

(println (str FG-GRAY "  fetching data..." RESET))

(let [data (fetch-all-data)
      synthetic? (get data :synthetic)]
  (render-header synthetic?)
  (render-coin "Bitcoin"  "BTC/USD" FG-BRIGHT-YELLOW
               (get data :btc-prices) (get data :btc-24h))
  (render-coin "Ethereum" "ETH/USD" FG-BRIGHT-CYAN
               (get data :eth-prices) (get data :eth-24h))
  (render-coin "Solana"   "SOL/USD" FG-MAGENTA
               (get data :sol-prices) (get data :sol-24h))
  (render-footer)
  (println (str FG-GRAY "  Golden cross = SMA(" fast-period ") crosses above SMA(" slow-period ") = bullish" RESET))
  (println (str FG-GRAY "  Death cross  = SMA(" fast-period ") crosses below SMA(" slow-period ") = bearish" RESET))
  (println ""))

)
