;; cyton_live_ingest.clj
;; ─────────────────────
;; OpenBCI Cyton (8-channel ADS1299) ingest demo for nanoclj-zig.
;;
;; The Cyton outputs raw 24-bit signed samples in its native binary format
;; over a 115200-baud serial link, but every OpenBCI GUI session also
;; produces an ASCII `OpenBCI-RAW-*.txt` file with the same data plus
;; metadata header lines.
;;
;; This example uses the existing `brainfloj-read` builtin to ingest one of
;; those files and computes the GF(3) trit classification of the recording
;; using the existing channel layout convention:
;;
;;     ch0 ch1   = Fp1 Fp2  (frontal salience)
;;     ch2 ch3   = C3  C4   (central / sensorimotor)
;;     ch4 ch5   = P7  P8   (parietal / DMN)
;;     ch6 ch7   = O1  O2   (occipital / visual)
;;
;; The fixture `examples/cyton_sample.txt` is a 25-sample synthetic
;; recording in the OpenBCI Cyton native format, including the four
;; metadata header lines (% prefix), the column header line, and 20
;; columns per data row (sample idx + 8 EXG + 3 accel + 5 other + 3
;; timestamp/marker fields).
;;
;; The header skip is handled automatically by `brainfloj-read`:
;;   - Lines starting with `%` are skipped (OpenBCI raw comment marker)
;;   - Lines where the first token after `column-offset` is non-numeric
;;     are skipped (column header row)
;;
;; The `:column-offset 1` arg tells the parser to skip the Sample Index
;; column. The `:channel-count 8` arg selects the next 8 floats as the
;; EXG channels.

;; ── ingest ─────────────────────────────────────────────────────────────

(def fixture-path "examples/cyton_sample.txt")

(def summary
  ;; (brainfloj-read path channel-count column-offset)
  ;; returns: {:samples N :channels 8 :sample0 [...] :means [...]
  ;;           :mins [...] :maxs [...] :entropy f64 :trit -1|0|+1}
  (brainfloj-read fixture-path 8 1))

;; ── inspect ────────────────────────────────────────────────────────────

(println "OpenBCI Cyton ingest demo")
(println "─────────────────────────")
(println (str "  fixture     : " fixture-path))
(println (str "  samples     : " (:samples summary)))
(println (str "  channels    : " (:channels summary)))
(println (str "  trit        : " (:trit summary)))
(println (str "  entropy     : " (:entropy summary)))
(println "")
(println "Per-channel means (μV):")
(let [labels ["Fp1" "Fp2" "C3 " "C4 " "P7 " "P8 " "O1 " "O2 "]
      means  (:means summary)]
  (doseq [i (range 8)]
    (println (str "  ch" i " " (nth labels i) "  " (nth means i)))))

;; ── trit interpretation ────────────────────────────────────────────────

(def trit-class
  (case (:trit summary)
    -1 "MINUS — left/frontal-dominant (validator phase, inhibitory)"
     0 "ERGODIC — balanced spatial distribution (coordinator phase)"
    +1 "PLUS  — right/posterior-dominant (generator phase, excitatory)"))

(println "")
(println (str "GF(3) classification: " trit-class))

;; ── what's next ────────────────────────────────────────────────────────
;;
;; To run against real Cyton hardware:
;;
;; 1. Plug the Cyton's USB dongle into your machine. The serial device
;;    appears as /dev/tty.usbserial-DM00Q0QF on macOS or /dev/ttyUSB0
;;    on Linux. Confirm with `ls /dev/tty.*` or `dmesg | tail`.
;;
;; 2. Use the OpenBCI GUI (https://docs.openbci.com/Software/OpenBCISoftware/GUIDocs/)
;;    to start a recording. The GUI writes the file to
;;    ~/Documents/OpenBCI_GUI/Recordings/OpenBCISession_*/OpenBCI-RAW-*.txt
;;
;; 3. Substitute that path for `fixture-path` above and re-run this script:
;;
;;        (def fixture-path "/path/to/OpenBCI-RAW-2026-04-12_03-00-00.txt")
;;
;;    No code changes needed — the parser handles the same format.
;;
;; 4. For a true real-time loop (no pre-recorded file), see the proposal
;;    in plurigrid/nanoclj-zig#1 — needs a streaming `brainfloj-tick`
;;    builtin built on top of the existing `parseDelimitedSummary`
;;    primitive, plus a Cyton binary packet parser at the lower layer
;;    (the existing CGX path in `src/cgx.zig` is the closest reference;
;;    Cyton's packet format is simpler: 0xA0 start byte, 1-byte sample
;;    index, 8 × 3-byte signed BE channel values, 6 bytes of accel,
;;    0xC0 stop byte, 33 bytes total).
