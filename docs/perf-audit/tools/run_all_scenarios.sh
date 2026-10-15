#!/bin/bash
F='^==|after load|^scan finished|^peak|scan window|emulated wall|GetSources calls|^ANx.After|^wrapped|^   AttuneNext|^modelled|^cached login|^Engine.PerfStats|^/an perf|^   [A-Za-z]|^UI renders|^predicate|^saved Saved|^loaded Saved|^PLAYER_LOGOUT|^after full GC|KB  Engine|KB  ANx|KB  Attune|ERROR|Traceback|Error|ZNAMES=2'
H=/tmp/claude-0/-home-user-AttuneNext/220b827c-c7aa-520c-bfdc-f183263ba2f0/scratchpad/gap_telemetry/harness.py
run() { echo; echo "######## $1   [expect: $2]"; shift 2; env "$@" python3 -I $H 2>&1 | grep -E "$F" | grep -v "frame  *[0-9]* *lua"; }
run "A stock" "harness_orig: scan 704-748, peak 129-148 MB, GS 66609 / rows 1357213, zoneCache 46 MB, ANx.db 7.4 MB" SCENARIO=stock PROFILE=1
run "B mismatch-names (fast bit + nil stub, same DB)" "same GS/rows as A, frames within noise" SCENARIO=mismatch-names
run "C fresh-scan ZNAMES=2 (new baseline)" "new numbers; zoneCache far below 46 MB; telemetry zoneFallback=0" SCENARIO=fresh-scan PROFILE=1 ADDON=/tmp/claude-0/-home-user-AttuneNext/220b827c-c7aa-520c-bfdc-f183263ba2f0/scratchpad/gap_telemetry/exp_tele
run "D heavy-tail" "gapx stock_w100_en: scan 950, peak 116 MB, GS 76372 / rows 8906355, zoneCache 1527 KB, ANx.db 5888 KB" SCENARIO=heavy-tail PROFILE=1
run "E 30fps paced" "gap2 fps30: ~419 scan frames, emulated wall 21.0 s, ~16.6 ms/frame, GC 4.7 ms/step" SCENARIO=30fps
run "F two-addons" "gap2 pair fps60: peak ~275 MB (handoff 261), ~431 scan frames, ~34 ms/frame" SCENARIO=two-addons
run "G cached-login" "svpack base: no rescan, ImportCache ~20 ms x2, idle immediately" SCENARIO=cached-login
run "H ui, stock bit (pred lens)" "pred: items(instance,600) ~12 ms, search 'item1' 134-190 ms, RemainingReport ~425 ms" SCENARIO=ui BITLIB=stock
run "I predicates, stock bit (ui_bench3)" "Eligible 12.45us IsAttunableAtAll 6.47us RemainingByCategory 783 ms" SCENARIO=fresh-scan BENCH=predicates BITLIB=stock FRAMES=900
run "I2 predicates, fast bit" "Eligible 2.33us IsAttunableAtAll 1.23us RemainingByCategory 253 ms" SCENARIO=fresh-scan BENCH=predicates FRAMES=900
