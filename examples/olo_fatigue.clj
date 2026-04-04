;; olo_fatigue.clj — Cone fatigue template for approximating olo (M-cone isolation)
;;
;; Physics: L and M cone sensitivity curves overlap 85%.
;; No natural light activates M cones alone.
;; But exhausting L cones via prolonged red-orange exposure
;; shifts the opponent balance toward M-dominant percept.
;;
;; Protocol:
;;   1. Stare at bright red-orange field (L-cone fatigue template) for 60s
;;   2. Switch to saturated teal/cyan target on neutral gray
;;   3. Fatigued L cones underrespond → M cones dominate → hyperbolic teal
;;
;; The closer to olo (0,1,0 in LMS) the teal appears,
;; the more successful the L-cone fatigue.
;;
;; Fatigue template color: bright red-orange maximizes L-cone stimulation
;; while minimally stimulating M cones.
;; sRGB: #FF4500 (OrangeRed) or #FF6600 — peak L-cone, low M-cone overlap
;;
;; Target color: maximum-saturation teal/cyan
;; sRGB: #00CED1 (DarkTurquoise) — strong M-cone, minimal L-cone
;;
;; Reference: Fong et al. 2025 "Novel color via stimulation of
;; individual photoreceptors at population scale" Science Advances

(def fatigue-color "FF4500")    ;; OrangeRed — maximal L-cone drive
(def target-color  "008080")    ;; Teal — M-cone dominant
(def neutral-gray  "808080")    ;; Adaptation reset
(def fatigue-duration-ms 60000) ;; 60 seconds staring
(def target-duration-ms  10000) ;; 10 seconds viewing

;; LMS cone response approximation (Smith & Pokorny fundamentals)
;; L-cone peak: ~565nm, M-cone peak: ~540nm, S-cone peak: ~440nm
;; OrangeRed (#FF4500): ~600nm dominant wavelength
;;   L response: 0.95, M response: 0.55, S response: 0.01
;; Teal (#008080): ~490nm dominant wavelength
;;   L response: 0.25, M response: 0.70, S response: 0.15

(def cone-responses
  {:fatigue {:L 0.95 :M 0.55 :S 0.01}
   :target  {:L 0.25 :M 0.70 :S 0.15}})

;; After 60s fatigue, L-cone sensitivity drops ~40-60%
;; Effective response when viewing teal after fatigue:
;;   L: 0.25 * 0.5 = 0.125 (halved by fatigue)
;;   M: 0.70 * 0.95 = 0.665 (mostly unfatigued)
;;   S: 0.15 * 1.0 = 0.15 (untouched)
;; Ratio M/L goes from 2.8 (normal) to 5.3 (post-fatigue)
;; This is the direction of olo in LMS space

(def post-fatigue-response
  {:L (* 0.25 0.5)   ;; 0.125
   :M (* 0.70 0.95)  ;; 0.665
   :S (* 0.15 1.0)}) ;; 0.15

;; Generate the HTML page
(def html-template
  (str
    "<!DOCTYPE html>\n"
    "<html><head><meta charset='utf-8'>\n"
    "<meta name='viewport' content='width=device-width,initial-scale=1'>\n"
    "<title>olo fatigue template</title>\n"
    "<style>\n"
    "* { margin: 0; padding: 0; box-sizing: border-box; }\n"
    "body { background: #" neutral-gray "; overflow: hidden; cursor: none; }\n"
    "#field { width: 100vw; height: 100vh; display: flex; align-items: center; justify-content: center; transition: background-color 0.1s; }\n"
    "#fixation { width: 20px; height: 20px; border-radius: 50%; background: #000; position: absolute; }\n"
    "#timer { position: fixed; bottom: 20px; right: 20px; color: #fff; font: 24px monospace; mix-blend-mode: difference; }\n"
    "#instructions { position: fixed; top: 50%; left: 50%; transform: translate(-50%,-50%); color: #fff; font: 20px sans-serif; text-align: center; max-width: 80vw; }\n"
    "</style></head><body>\n"
    "<div id='field'><div id='fixation'></div></div>\n"
    "<div id='timer'></div>\n"
    "<div id='instructions'>\n"
    "  <p>OLO FATIGUE TEMPLATE</p>\n"
    "  <p style='margin-top:20px;font-size:14px'>Approximating olo via L-cone exhaustion</p>\n"
    "  <p style='margin-top:10px;font-size:14px'>Tap/click anywhere to begin</p>\n"
    "  <p style='margin-top:10px;font-size:12px;opacity:0.6'>Fullscreen recommended (press F)</p>\n"
    "</div>\n"
    "<script>\n"
    "const FATIGUE_MS = " fatigue-duration-ms ";\n"
    "const TARGET_MS = " target-duration-ms ";\n"
    "const field = document.getElementById('field');\n"
    "const timer = document.getElementById('timer');\n"
    "const instructions = document.getElementById('instructions');\n"
    "const fixation = document.getElementById('fixation');\n"
    "let phase = 'ready';\n"
    "let startTime = 0;\n"
    "\n"
    "document.addEventListener('keydown', e => {\n"
    "  if (e.key === 'f' || e.key === 'F') {\n"
    "    if (!document.fullscreenElement) document.documentElement.requestFullscreen();\n"
    "    else document.exitFullscreen();\n"
    "  }\n"
    "  if (e.key === 'Escape' && phase !== 'ready') { reset(); }\n"
    "  if (e.key === ' ' && phase === 'ready') { startFatigue(); }\n"
    "});\n"
    "\n"
    "field.addEventListener('click', () => {\n"
    "  if (phase === 'ready') startFatigue();\n"
    "});\n"
    "\n"
    "function startFatigue() {\n"
    "  phase = 'fatigue';\n"
    "  instructions.style.display = 'none';\n"
    "  field.style.backgroundColor = '#" fatigue-color "';\n"
    "  fixation.style.background = '#000';\n"
    "  startTime = Date.now();\n"
    "  requestAnimationFrame(tick);\n"
    "}\n"
    "\n"
    "function tick() {\n"
    "  const elapsed = Date.now() - startTime;\n"
    "  if (phase === 'fatigue') {\n"
    "    const remaining = Math.max(0, Math.ceil((FATIGUE_MS - elapsed) / 1000));\n"
    "    timer.textContent = remaining + 's';\n"
    "    if (elapsed >= FATIGUE_MS) {\n"
    "      phase = 'target';\n"
    "      field.style.backgroundColor = '#" target-color "';\n"
    "      fixation.style.background = '#fff';\n"
    "      startTime = Date.now();\n"
    "    }\n"
    "  } else if (phase === 'target') {\n"
    "    const remaining = Math.max(0, Math.ceil((TARGET_MS - elapsed) / 1000));\n"
    "    timer.textContent = 'OLO ' + remaining + 's';\n"
    "    if (elapsed >= TARGET_MS) {\n"
    "      phase = 'gray';\n"
    "      field.style.backgroundColor = '#" neutral-gray "';\n"
    "      fixation.style.background = '#000';\n"
    "      timer.textContent = 'look at the gray — see the afterimage';\n"
    "      setTimeout(reset, 15000);\n"
    "    }\n"
    "  }\n"
    "  if (phase !== 'ready') requestAnimationFrame(tick);\n"
    "}\n"
    "\n"
    "function reset() {\n"
    "  phase = 'ready';\n"
    "  field.style.backgroundColor = '#" neutral-gray "';\n"
    "  fixation.style.background = '#000';\n"
    "  timer.textContent = '';\n"
    "  instructions.style.display = 'block';\n"
    "}\n"
    "</script></body></html>"))

;; Write to file
(spit "olo_fatigue.html" html-template)
(println "Wrote olo_fatigue.html")
(println "Open in browser, go fullscreen (F), tap to start")
(println "Phase 1: 60s red-orange field (stare at center dot)")
(println "Phase 2: teal field appears — observe hyperbolic saturation")
(println "Phase 3: gray field — observe teal afterimage")
(println)
(println "LMS analysis:")
(println "  Fatigue template L/M ratio:" (/ 0.95 0.55))
(println "  Normal teal M/L ratio:" (/ 0.70 0.25))
(println "  Post-fatigue teal M/L ratio:" (/ 0.665 0.125))
(println "  Improvement factor:" (/ (/ 0.665 0.125) (/ 0.70 0.25)))
