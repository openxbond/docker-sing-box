#!/usr/bin/env bash
# 官方 sing-box 客戶端映像入口：拉取訂閱設定 → 按模式推導運行設定 → sing-box
# check 校驗 → 原子套用。行為契約見 xbond 倉庫 docs/specs/docker-client.md；
# 本檔案是該契約的實現。
#
# 設計要點：
# - 原始設定與運行設定分離：config.source 原樣緩存端點簽發的內容；
#   config.json 每次按當前 MODE 從原始設定推導（tun 補 auto_redirect、port
#   刪 tun 入站）。切換模式重啟即可重建，304 與離線同樣自愈——只改運行設定
#   而不重拉，正是為了模式切換不依賴網絡。
# - 家電語義：除了 sing-box 子程序意外退出，容器不主動退出——拉取失敗、設定
#   校驗失敗、環境變數寫錯都只是記錄加按節奏重試；交由 `restart: always` 處理
#   的只有真正的崩潰。
# - 設定永不回退：config.json 永遠是最近一次通過 sing-box check 的內容；
#   校驗不過的新設定直接丟棄，運行中的程序不受影響。
# - 快取標籤只在設定通過校驗後保存，保證 304 不會跳過一個曾經失敗的內容。
set -u -o pipefail

STATE_DIR=/etc/sing-box            # 卷：原始設定、運行設定與快取標籤
RUN_DIR=/run/xbond-sing-box        # 臨時區：下載暫存與健康檢查連接埠
SOURCE=$STATE_DIR/config.source       # 無 .json 後綴：-C 會載入目錄內所有 .json
CONFIG=$STATE_DIR/config.json
ETAG_FILE=$STATE_DIR/.etag
SOURCE_TMP=$RUN_DIR/config.source.new
CANDIDATE=$RUN_DIR/config.new
PORT_FILE=$RUN_DIR/mixed-port
NFT_TABLE="inet sing-box"          # auto_redirect 留下的 nftables 表
DEFAULT_INTERVAL=86400             # 24 小時
MIN_INTERVAL=600                   # 10 分鐘，防止誤配的間隔衝擊訂閱端點
FIRST_RETRY_SECONDS=30
WGET_TIMEOUT=60
STOP=0
CHILD_PID=

log() { printf '[xbond-sing-box] %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

cleanup_nft() { nft delete table $NFT_TABLE 2>/dev/null || true; }

# ---------- 環境變數 ----------

parse_interval() {  # 接受 90 / 90m / 24h / 7d；非法時無輸出且返回 1
  local v="${1:-}" n
  [ -n "$v" ] || return 1
  if [[ $v =~ ^[0-9]+$ ]]; then
    echo "$v"
    return 0
  fi
  [[ $v =~ ^([0-9]+)([smhd])$ ]] || return 1
  n=${BASH_REMATCH[1]}
  case ${BASH_REMATCH[2]} in
    s) echo "$n" ;;
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    d) echo $((n * 86400)) ;;
  esac
}

resolve_settings() {
  SUB_URL_OK=1
  if [ -z "${SUB_URL:-}" ] || [[ ! $SUB_URL =~ ^https?:// ]]; then
    log "錯誤：SUB_URL 未設定或不是 http(s) 訂閱連結；請先在瀏覽器開啟訂閱連結確認內容，再以 -e SUB_URL=... 傳入"
    SUB_URL_OK=0
  fi

  MODE=${MODE:-tun}
  case $MODE in
    tun | port) ;;
    *)
      log "警告：MODE=$MODE 無效，按 tun 處理"
      MODE=tun
      ;;
  esac

  local raw parsed
  raw=${UPDATE_INTERVAL:-}
  parsed=$(parse_interval "$raw")
  if [ -z "$parsed" ]; then
    [ -n "$raw" ] && log "警告：UPDATE_INTERVAL='$raw' 無法解析，按 24 小時處理"
    UPDATE_INTERVAL=$DEFAULT_INTERVAL
  elif [ "$parsed" -lt "$MIN_INTERVAL" ]; then
    log "警告：UPDATE_INTERVAL 低於下限，按 10 分鐘處理"
    UPDATE_INTERVAL=$MIN_INTERVAL
  else
    UPDATE_INTERVAL=$parsed
  fi
}

# ---------- 拉取 → 推導 → 校驗 → 套用 ----------

mode_filter() {  # 按 MODE 輸出 jq 過濾器
  case $MODE in
    tun) echo '.inbounds |= map(if .type == "tun" then . + {auto_redirect: true} else . end)' ;;
    port) echo '.inbounds |= map(select(.type != "tun"))' ;;
  esac
}

fetch_config() {  # 結果寫入 FETCH_STATUS：downloaded | unchanged | error
  FETCH_STATUS=error
  mkdir -p "$RUN_DIR"
  rm -f "$SOURCE_TMP" "$RUN_DIR/etag.new"
  local args=(-q -S -T "$WGET_TIMEOUT" -O "$SOURCE_TMP")
  if [ -s "$ETAG_FILE" ]; then
    args+=(--header="If-None-Match: $(cat "$ETAG_FILE")")
  fi
  local raw rc status etag
  raw=$(wget "${args[@]}" "$SUB_URL" 2>&1 | tr -d '\r')
  rc=$?
  # 相容 busybox（縮排的回應行）與 GNU wget 的輸出形態，取最後一個狀態行
  status=$(printf '%s\n' "$raw" | sed -n 's/.*HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' | tail -n 1)
  case "$rc:$status" in
    0:200)
      etag=$(printf '%s\n' "$raw" | sed -n 's/^[[:space:]]*[Ee][Tt]ag:[[:space:]]*\(.*\)$/\1/p' | tail -n 1)
      if [ -n "$etag" ]; then
        printf '%s\n' "$etag" > "$RUN_DIR/etag.new"
      fi
      FETCH_STATUS=downloaded
      ;;
    *:304)
      FETCH_STATUS=unchanged
      ;;
    *)
      log "訂閱拉取失敗（HTTP ${status:-無回應}），保留現有設定繼續運行；401/403 時請在瀏覽器開啟訂閱連結查看狀態頁（封禁／套餐／配額都會在那裏說明）"
      ;;
  esac
}

derive_candidate() {  # 從原始設定按 MODE 產出候選運行設定，0=通過校驗
  local src=$1 filter out
  filter=$(mode_filter)
  if ! jq -e "$filter" "$src" > "$CANDIDATE" 2>/dev/null; then
    log "設定無效：內容不是可解析的訂閱設定 JSON，已丟棄"
    rm -f "$CANDIDATE"
    return 1
  fi
  if ! out=$(sing-box check -c "$CANDIDATE" 2>&1); then
    log "新設定未通過 sing-box check，保留現有設定：${out}"
    rm -f "$CANDIDATE"
    return 1
  fi
}

install_candidate() {  # 0=已套用；2=內容無變化
  if [ ! -f "$CONFIG" ]; then
    mv "$CANDIDATE" "$CONFIG"
    write_port_file
    return 0
  fi
  if cmp -s "$CANDIDATE" "$CONFIG"; then
    rm -f "$CANDIDATE"
    log "訂閱設定無變化"
    return 2
  fi
  mv "$CANDIDATE" "$CONFIG"
  write_port_file
  log "訂閱設定有變化"
  # 啟動階段由 main 統一拉起子程序；運行期才在這裡重啟
  if [ -n "$CHILD_PID" ]; then
    log "重新啟動 sing-box"
    restart_child
  fi
  return 0
}

apply_download() {  # 新內容已下載到 SOURCE_TMP：先推導校驗，通過才提升為來源
  derive_candidate "$SOURCE_TMP" || return 1
  # 校驗通過才保存來源與快取標籤：304 永遠不會跳過一個曾經失敗的內容
  mv "$SOURCE_TMP" "$SOURCE"
  if [ -f "$RUN_DIR/etag.new" ]; then
    mv "$RUN_DIR/etag.new" "$ETAG_FILE"
  else
    rm -f "$ETAG_FILE"
  fi
  install_candidate
}

derive_runtime() {  # 無新內容（304／啟動）時，從已緩存來源按當前模式重建
  [ -f "$SOURCE" ] || return 1
  derive_candidate "$SOURCE" || return 1
  install_candidate
}

update_once() {  # 一輪完整同步；任何失敗都只記錄，不拋給調用方
  fetch_config
  case $FETCH_STATUS in
    downloaded)
      apply_download || true
      ;;
    unchanged)
      log "訂閱無更新（304），按當前模式檢查運行設定"
      derive_runtime || true
      ;;
  esac
  return 0
}

write_port_file() {  # 健康檢查探測目前設定的 mixed 連接埠，連接埠運行期從設定讀取
  jq -er '[.inbounds[] | select(.type == "mixed")][0].listen_port' "$CONFIG" > "$PORT_FILE" 2>/dev/null ||
    echo 7890 > "$PORT_FILE"
}

# ---------- sing-box 子程序 ----------

start_child() {
  sing-box run -D "$STATE_DIR" -C "$STATE_DIR" &
  CHILD_PID=$!
  log "sing-box 已啟動（pid $CHILD_PID，模式 $MODE）"
}

stop_child() {
  [ -n "$CHILD_PID" ] || return 0
  if ! kill -TERM "$CHILD_PID" 2>/dev/null; then
    wait "$CHILD_PID" 2>/dev/null
    CHILD_PID=
    return 0
  fi
  local i
  for i in $(seq 1 20); do
    kill -0 "$CHILD_PID" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$CHILD_PID" 2>/dev/null; then
    log "sing-box 未於 10 秒內退出，發送 SIGKILL"
    kill -KILL "$CHILD_PID" 2>/dev/null || true
  fi
  wait "$CHILD_PID" 2>/dev/null
  CHILD_PID=
}

restart_child() {
  stop_child
  cleanup_nft
  start_child
}

# ---------- 排程 ----------

# 下一次觸發時刻：本地 04:00 + n×間隔，嚴格大於 now。純函數，供單測
# （tests/next-tick.test.sh）與真實排程共用。
next_tick() {  # 參數：now（epoch 秒）、間隔（秒）
  local now=$1 interval=$2 h m s base n
  read -r h m s <<< "$(date -d "@$now" '+%H %M %S')"
  h=$((10#$h))
  m=$((10#$m))
  s=$((10#$s))
  base=$((now - h * 3600 - m * 60 - s + 4 * 3600))    # 今天本地 04:00
  [ "$now" -lt "$base" ] && base=$((base - 86400))    # 尚未到今天的 04:00 則基點取昨天
  n=$(( (now - base) / interval + 1 ))
  echo $((base + n * interval))
}

sleep_until() {  # 分片睡眠，保持 5 秒級的停止與子程序存活回應；被喚醒返回 1
  local target=$1 now
  while [ "$STOP" -eq 0 ]; do
    now=$(date +%s)
    [ "$now" -ge "$target" ] && return 0
    sleep 5 &
    wait $! || true
    [ "$STOP" -eq 1 ] && return 1
    if [ -n "$CHILD_PID" ] && ! kill -0 "$CHILD_PID" 2>/dev/null; then
      local code
      wait "$CHILD_PID"
      code=$?
      CHILD_PID=
      log "sing-box 意外退出（退出碼 $code），容器隨之退出"
      exit "$code"
    fi
  done
  return 1
}

main() {
  resolve_settings
  mkdir -p "$STATE_DIR" "$RUN_DIR"
  cleanup_nft    # 清掉上次非正常退出殘留的表

  # 舊卷遷移：只有運行設定、沒有原始設定時，把現有內容當作來源（可能已按
  # 另一模式變換過；若曾切換模式，刪卷重建即可恢復完整原始內容）。
  if [ ! -f "$SOURCE" ] && [ -f "$CONFIG" ]; then
    cp "$CONFIG" "$SOURCE"
    log "舊卷缺少原始設定，已把現有 config.json 遷移為來源；曾切換過模式時建議刪卷重建"
  fi

  # 啟動必拉一次；拿到第一份可用設定前按節奏重試，容器不退出
  while :; do
    [ "$STOP" -eq 1 ] && exit 0
    if [ "$SUB_URL_OK" -eq 1 ]; then
      update_once
    fi
    [ -f "$CONFIG" ] && break
    log "尚無可用設定，${FIRST_RETRY_SECONDS}s 後重試"
    sleep_until "$(( $(date +%s) + FIRST_RETRY_SECONDS ))" && true || exit 0
  done

  start_child
  local next
  next=$(next_tick "$(date +%s)" "$UPDATE_INTERVAL")
  log "排程：每 ${UPDATE_INTERVAL}s，錨定本地 04:00；下次更新 $(date -d "@$next" '+%F %T %Z')"
  while sleep_until "$next"; do
    update_once
    next=$(next_tick "$(date +%s)" "$UPDATE_INTERVAL")
  done
  log "收到停止訊號，退出"
  exit 0
}

on_signal() { STOP=1; }
trap on_signal TERM INT
trap cleanup_nft EXIT

case "${1:-}" in
  next-tick)       # 測試入口：next-tick NOW INTERVAL
    next_tick "$2" "$3"
    ;;
  parse-interval)  # 測試入口：parse-interval 值
    parse_interval "$2"
    ;;
  *)
    main
    ;;
esac
