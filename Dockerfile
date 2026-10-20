# 客戶端運行時映像：基於上游 sing-box 對應版本，只疊加入口腳本與所需工具，
# 不自行編譯 sing-box；行為差異全部在 entrypoint.sh 裏。行為契約見 xbond
# 倉庫 docs/specs/docker-client.md。
#
# NET_ADMIN 與 /dev/net/tun 由運行方在網關模式下授予，映像內不預設特權；
# 容器以 root 運行是 TUN 的要求（需要 CAP_NET_ADMIN）。
ARG SINGBOX_VERSION=v1.13.12
FROM ghcr.io/sagernet/sing-box:${SINGBOX_VERSION}

# bash：入口腳本；jq：模式變換（給 tun 入站補 auto_redirect / 刪除 tun 入站）；
# nftables：退出時清理 auto_redirect 留下的 nftables 表；tzdata：缺少時 TZ
# 無效，排程錨點會回落為 UTC。
RUN apk add --no-cache bash jq nftables tzdata

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

ARG SINGBOX_VERSION
LABEL org.opencontainers.image.title="xbond sing-box client" \
    org.opencontainers.image.description="XBond 訂閱的 sing-box Docker 客戶端：網關／連接埠雙模式，定時更新訂閱設定" \
    org.opencontainers.image.source="https://github.com/openxbond/docker-sing-box" \
    org.opencontainers.image.version=${SINGBOX_VERSION}

# 健康檢查探測目前設定的 mixed 連接埠：連接埠由入口腳本運行期從設定讀取寫入
# /run，因此無需額外環境變數；預設回落 7890（訂閱端點的預設偏好連接埠）。
# 啟動期（首次拉取失敗重試中）健康檢查失敗是預期訊號：容器可啟動但尚無代理連接埠。
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD bash -c 'port=$(cat /run/xbond-sing-box/mixed-port 2>/dev/null || echo 7890); exec 3<>/dev/tcp/127.0.0.1/"$port"' || exit 1

ENTRYPOINT ["/entrypoint.sh"]
