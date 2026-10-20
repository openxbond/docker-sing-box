#!/usr/bin/env bash
# 官方 sing-box 客戶端映像入口：拉取訂閱設定 → 按模式變換 → sing-box check
# 校驗 → 原子套用。行為契約見 xbond 倉庫 docs/specs/docker-client.md；本檔案
# 是該契約的實現。
#
# 設計要點：
# - 家電語義：除了 sing-box 子程序意外退出，容器不主動退出——拉取失敗、設定
#   校驗失敗、環境變數寫錯都只是記錄加按節奏重試；交由 `restart: always` 處理
#   的只有真正的崩潰。
# - 設定永不回退：卷內 config.json 永遠是最近一次通過 sing-box check 的內容；
#   校驗不過的新設定直接丟棄，運行中的程序不受影響。
# - 快取標籤只在設定通過校驗後保存，保證 304 不會跳過一個曾經失敗的內容。
set -u -o pipefail

STATE_DIR=/etc/sing-box            # 卷：運行中設定與快取標籤
RUN_DIR=/run/xbond-sing-box        # 臨時區：下載暫存與健康檢查連接埠
CONFIG=$STATE_DIR/config.json
ETAG_FILE=$STATE_DIR/.etag
NEW_CONFIG=$RUN_DIR/config.new
PORT_FILE=$RUN_DIR/mixed-port
NFT_TABLE="inet sing-box"          # sing-box auto_redirect 的 nftables 表
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

# ---------- 拉取 → 變換 → 校驗 → 套用 ----------

fetch_config() {  # 結果寫入 FETCH_STATUS：downloaded | unchanged | error
  FETCH_STATUS=error
  mkdir -p "$RUN_DIR"
  rm -f "$NEW_CONFIG"
  local args=(-q -S -T "$WGET_TIMEOUT" -O "$NEW_CONFIG")
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
      else
        rm -f "$RUN_DIR/etag.new"
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

transform_config() {  # 0=成功；失敗即回應不是可解析的訂閱設定 JSON
  local filter
  case $MODE in
    tun) filter='.inbounds |= map(if .type == "tun" then . + {auto_redirect: true} else . end)' ;;
    port) filter='.inbounds |= map(select(.type != "tun"))' ;;
  esac
  jq -e "$filter" "$NEW_CONFIG" > "$NEW_CONFIG.tmp" 2>/dev/null || {
    log "設定無效：回應不是可解析的訂閱設定 JSON，已丟棄"
    return 1
  }
  mv "$NEW_CONFIG.tmp" "$NEW_CONFIG"
}

validate_config() {  # 0=通過 sing-box check
  local out
  if ! out=$(sing-box check -c "$NEW_CONFIG" 2>&1); then
    log "新設定未通過 sing-box check，保留現有設定：${out}"
    return 1
  fi
}

write_port_file() {  # 健康檢查探測目前設定的 mixed 連接埠，連接埠運行期從設定讀取
  jq -er '[.inbounds[] | select(.type == "mixed")][0].listen_port' "$CONFIG" > "$PORT_FILE" 2>/dev/null ||
    echo 7890 > "$PORT_FILE"
}

# 返回值：0=已套用（首次落盤或已重啟）；1=新設定無效；2=內容無變化
apply_config() {
  transform_config || return 1
  validate_config || return 1
  # 校驗通過才保存快取標籤：304 永遠不會跳過一個曾經失敗的內容
  if [ -f "$RUN_DIR/etag.new" ]; then
    mv "$RUN_DIR/etag.new" "$ETAG_FILE"
  else
    rm -f "$ETAG_FILE"
  fi
  if [ ! -f "$CONFIG" ]; then
    mv "$NEW_CONFIG" "$CONFIG"
    write_port_file
    return 0
  fi
  if cmp -s "$NEW_CONFIG" "$CONFIG"; then
    rm -f "$NEW_CONFIG"
    log "訂閱設定無變化"
    return 2
  fi
  mv "$NEW_CONFIG" "$CONFIG"
  write_port_file
  log "訂閱設定有變化，重新啟動 sing-box"
  restart_child
  return 0
}

update_once() {  # 一輪完整的拉取→套用；任何失敗都只記錄，不拋給調用方
  fetch_config
  case $FETCH_STATUS in
    unchanged)
      log "訂閱無更新（304）"
      ;;
    downloaded)
      apply_config || true
      ;;
  esac
  return 0
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

  # 啟動必拉一次；拿到第一份可用設定前按節奏重試，容器不退出
  while [ ! -f "$CONFIG" ]; do
    [ "$STOP" -eq 1 ] && exit 0
    if [ "$SUB_URL_OK" -eq 1 ]; then
      update_once
    else
      log "尚無可用設定，${FIRST_RETRY_SECONDS}s 後重試"
    fi
    [ -f "$CONFIG" ] && break
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
