#!/bin/sh
# Measures how fast Frost follows window changes and what it costs, and prints a Markdown table
# for docs/testing.md. Frost must be running. Takes about 30 seconds and opens test windows,
# so leave the mouse and keyboard alone until it prints.
set -e
cd "$(dirname "$0")"
pid=$(pgrep -x Frost) || { echo "Frost is not running" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

app="$tmp/FrostBench.app"
mkdir -p "$app/Contents/MacOS"
swiftc -O latency.swift -o "$app/Contents/MacOS/FrostBench"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>FrostBench</string>
  <key>CFBundleIdentifier</key><string>local.frost.bench</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
codesign -s - --force "$app" 2>/dev/null

open -n -W "$app" --args keys "$tmp/keys"      # in front: keyboard-style switches
open -n -g -W "$app" --args raise "$tmp/raise" # in the background: windows popping up

# CPU and memory over 10 seconds (top's first sample has no CPU figure yet)
usage=$(top -l 6 -s 2 -pid "$pid" -stats pid,cpu,mem | awk -v p="$pid" '$1 == p { n++; if (n > 1) { c += $2; m = $3 } } END { gsub(/[+-]/, "", m); printf "%.1f%% %s", c / (n - 1), m }')

misses=0
row() {  # row <title> <file>
  read -r avg max count missed < "$2" || true
  if [ "$avg" = nofront ]; then echo "| $1 | 측정 못 함 | | |"; misses=1; return; fi
  note=""; if [ "$missed" -gt 0 ]; then note=" (놓침 $missed)"; misses=1; fi
  echo "| $1 | ${avg}ms | ${max}ms | $count$note |"
}
echo "측정: $(date +%Y-%m-%d), macOS $(sw_vers -productVersion), $(sysctl -n hw.model) ($(sysctl -n machdep.cpu.brand_string))"
echo
echo "| 측정 | 평균 | 최대 | 횟수 |"
echo "|---|---|---|---|"
row "같은 앱 안 창 전환 (⌘\`처럼)" "$tmp/keys"
row "뒤에서 다른 창이 올라올 때" "$tmp/raise"
echo "| CPU · 메모리 (10초) | ${usage% *} | ${usage#* } | |"
if [ $misses = 1 ]; then
  echo
  echo "측정 중에 다른 앱이 앞으로 왔다. 마우스와 키보드를 놓고 다시 돌린다." >&2
fi
