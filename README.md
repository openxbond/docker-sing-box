# xbond sing-box 客戶端映像

把 XBond 訂閱連結部署為 Docker 容器：網關模式接管整機／局域網流量，或連接埠模式在任何 Docker 宿主機上提供本地代理；容器按排程自動更新訂閱設定。

映像基於上游 [sagernet/sing-box](https://github.com/SagerNet/sing-box) 對應版本，只加入一份入口腳本 [entrypoint.sh](entrypoint.sh)；拉取、變換、校驗與更新的邏輯都在這個腳本裏。

## 快速開始

推薦經控制台訂閱頁的 Docker 卡片複製已填好你訂閱連結與連接埠的命令；以下為手動等價形式（把 `SUB_URL` 換成你的訂閱連結）。

網關模式（Linux 宿主機：軟路由／NAS／伺服器，TUN 全局接管）：

```sh
docker run -d --name xbond-sing-box --restart always \
  --network host --cap-add NET_ADMIN --device /dev/net/tun \
  -v xbond-sing-box:/etc/sing-box \
  -e TZ=Asia/Shanghai \
  -e SUB_URL='https://example.xbond.dev/api/subscription/config?token=YOUR_SUBSCRIPTION_TOKEN&target=sing-box&lang=zh-HK' \
  ghcr.io/openxbond/sing-box:v1.13.21
```

連接埠模式（任何 Docker 宿主機，含 macOS／Windows 的 Docker Desktop；自行把系統或瀏覽器代理指向 `7890`）：

```sh
docker run -d --name xbond-sing-box --restart always \
  -p 7890:7890 \
  -v xbond-sing-box:/etc/sing-box \
  -e TZ=Asia/Shanghai -e MODE=port \
  -e SUB_URL='https://example.xbond.dev/api/subscription/config?token=YOUR_SUBSCRIPTION_TOKEN&target=sing-box&lang=zh-HK' \
  ghcr.io/openxbond/sing-box:v1.13.21
```

偏好 docker compose 的用 [compose.example.yaml](compose.example.yaml)，兩種模式的差異都在註釋裏。

## 環境變數

| 變數 | 必需 | 預設 | 說明 |
| --- | --- | --- | --- |
| `SUB_URL` | 是 | — | 訂閱連結（`target=sing-box`）。未設定或不是 http(s) 時容器不啟動 sing-box，按節奏記錄可操作的錯誤。 |
| `MODE` | 否 | `tun` | `tun` 網關模式；`port` 連接埠模式。非法值記錄後按預設處理。 |
| `UPDATE_INTERVAL` | 否 | `24h` | 更新間隔，接受 `90`／`90m`／`24h`／`7d`；低於 10 分鐘按 10 分鐘處理。 |
| `TZ` | 否 | UTC | 容器本地時區，決定更新錨點。 |

## 更新機制

- 啟動必拉一次；拿到第一份可用設定前每 30 秒重試，容器不退出。
- 之後按 `UPDATE_INTERVAL` 排程：觸發時刻 = 本地 04:00 + n×間隔（預設即每日 04:00）。
- 拉取走 ETag：內容無變化是 304 空回應，不重複下載。
- 新設定先經 `sing-box check` 校驗，不通過直接丟棄——已存設定永不回退，運行中的連接不中斷。
- 設定有變化才在容器內重新啟動 sing-box（容器本身不退出）。
- 拉取失敗（網絡問題、401／403）保留現有設定繼續運行；401／403 時在瀏覽器開啟訂閱連結查看狀態頁，封禁／套餐／配額都會在那裏說明。

## 兩種模式

**網關模式**（預設）：宿主網絡 + `NET_ADMIN` + `/dev/net/tun`，TUN 接管所在主機的流量；宿主機開啟轉發時局域網設備可經其上網，mixed 代理連接埠（7890）與開啟時的 clash_api 連接埠同時對局域網開放。僅支援 Linux 宿主機——macOS／Windows 的 Docker Desktop 中容器運行在 Linux 虛擬機內，TUN 無法接管宿主機流量，這是虛擬化的邊界，不是設定問題。

**連接埠模式**：設定中只有 mixed 入站，容器以連接埠映射發佈代理連接埠；適用於任何 Docker 宿主機。發佈連接埠取你偏好裏的 mixed 連接埠，開啟 clash_api 時追加對應連接埠。

## 疑難排解

- 日誌前綴 `[xbond-sing-box]`：`docker logs xbond-sing-box` 查看拉取、校驗與排程記錄。
- `operation not permitted` 或 `/dev/net/tun: no such file`：網關模式缺少 `--cap-add NET_ADMIN` 或 `--device /dev/net/tun`；此時 sing-box 無法啟動，容器會反覆重啟並在日誌中記錄原因。
- 啟動初期偶發 `add route: no route to host` 後退出：多半是宿主機網絡尚未就緒（例如開機過程中），或仍有舊的代理容器／殘留路由規則在搶占時的競態，`restart: always` 會自動重試並自癒；持續失敗時，確認仍有舊容器在運行則先停掉它。
- 從手寫 compose 遷移：舊容器與卷的名稱可能與本映像的 `xbond-sing-box` 命名衝突，先 `docker compose down` 舊服務再啟動新的。
- 連接埠衝突：宿主機已有服務佔用 7890／19090 時，改用偏好裏的其他連接埠並同步修改映射。
- 控制台生成的命令中的連接埠是生成時刻的偏好快照，之後修改偏好不會回填已複製的命令。

## 開發

```
entrypoint.sh            入口腳本：全部行為邏輯（行為契約見 xbond 倉庫 docs/specs/docker-client.md）
tests/next-tick.test.sh  排程語義與間隔解析的單測
Dockerfile               上游映像 + bash/jq/nftables/tzdata + 入口腳本
build.sh                 本地建置（預設本機平台；--push 全架構推送）
compose.example.yaml     兩種模式的示例編排
.github/workflows/       ci.yml（日常檢查）與 image.yml（v* 標籤發佈）
```

本地驗證：

```sh
bash tests/next-tick.test.sh   # 排程語義
shellcheck -S error entrypoint.sh build.sh
./build.sh                     # 建置 docker-sing-box:dev
```

## 發佈

推送 `v*` 標籤觸發 CI 多架構發佈：`v1.13.21` 發佈映像 `latest` 與 `v1.13.21`；修訂後綴 `-rN`（如 `v1.13.21-r2`）只存在於 git 一側，映像標籤仍為 `v1.13.21`——修復入口腳本不提升上游版本時用它重發。上游版本固定、由維護者驗證後升級，映像不自動跟隨上游浮動。GHCR 包首次發佈後需在 GitHub 包設定裏翻轉為 public（一次性）。

## 安全說明

`SUB_URL` 等同你的訂閱憑證：能讀取它的人可以取得你的節點設定。環境變數對同一宿主機的其他用戶可見（`docker inspect`），單用戶家用機可接受；若懷疑洩露，在控制台重設訂閱憑證即可令舊連結失效。

## 授權

未附授權條款；版權歸倉庫所有者。
