#!/usr/bin/env bash
# 排程語義單測：「下次觸發時刻 = 本地 04:00 + n×間隔」。
# 時間基準：1792540800 = 2026-10-21 00:00:00 UTC（週三）。
# 04:00 UTC = 1792555200；05:30 UTC = 1792561800；03:00 UTC = 1792551600。
set -u
here=$(cd "$(dirname "$0")" && pwd)
script=$here/../entrypoint.sh
fails=0

check() {    # 描述 期望 實際
  if [ "$2" = "$3" ]; then
    printf 'ok - %s\n' "$1"
  else
    printf 'not ok - %s（期望 %s，實際 %s）\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

next() {     # TZ NOW INTERVAL → 輸出
  TZ=$1 bash "$script" next-tick "$2" "$3"
}

# UTC，24 小時間隔：05:30 → 次日 04:00（錨定，而非「恰好 24 小時後的 05:30」）
check "UTC 05:30 + 24h → 次日 04:00" 1792641600 "$(next UTC 1792561800 86400)"
# UTC，24 小時間隔：03:00 → 今天 04:00（今天錨點未到，基點取昨天）
check "UTC 03:00 + 24h → 今天 04:00" 1792555200 "$(next UTC 1792551600 86400)"
# 恰在錨點上：下一個觸發嚴格大於現在
check "UTC 04:00 + 24h → 次日 04:00" 1792641600 "$(next UTC 1792555200 86400)"
# 小間隔對齊到 04:00 + n×間隔
check "UTC 05:30 + 1h → 06:00" 1792562400 "$(next UTC 1792561800 3600)"
# 間隔大於一天：錨點 + n×間隔，不落回每日 04:00
check "UTC 05:30 + 25h → 次日 05:00" 1792645200 "$(next UTC 1792561800 90000)"
# 本地時區：now = 2026-10-21 13:30 +08 → 2026-10-22 04:00 +08。
# 本機缺少時區資料（如 Windows Git Bash）時 TZ 靜默回落 UTC，跳過該用例；
# CI 的 ubuntu 帶完整 zoneinfo，會強制執行它。
if TZ=Asia/Shanghai date +%z 2>/dev/null | grep -q '+0800'; then
  check "Asia/Shanghai 13:30 + 24h → 次日本地 04:00" 1792612800 "$(next Asia/Shanghai 1792561800 86400)"
else
  printf 'skip - Asia/Shanghai 用例（本機缺少時區資料，TZ 回落 UTC）\n'
fi

# 間隔解析：接受純秒數與 s/m/h/d 單位；非法與空輸入無輸出、非零退出
check "parse 90" 90 "$(bash "$script" parse-interval 90)"
check "parse 90m" 5400 "$(bash "$script" parse-interval 90m)"
check "parse 24h" 86400 "$(bash "$script" parse-interval 24h)"
check "parse 7d" 604800 "$(bash "$script" parse-interval 7d)"
out=$(bash "$script" parse-interval abc 2>/dev/null); rc=$?
check "parse abc 輸出為空" "" "$out"
check "parse abc 非零退出" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
out=$(bash "$script" parse-interval 1.5h 2>/dev/null); rc=$?
check "parse 1.5h 輸出為空" "" "$out"
check "parse 空字串非零退出" "1" "$(bash "$script" parse-interval "" >/dev/null 2>&1 && echo 0 || echo 1)"

if [ "$fails" -eq 0 ]; then
  echo "全部通過"
else
  echo "失敗 $fails 項"
  exit 1
fi
