## 倉庫性質

XBond 官方 sing-box 客戶端映像的獨立公開倉庫：上游 sing-box 映像 + 入口腳本。行為契約在 xbond 主倉庫 `docs/specs/docker-client.md`，本倉庫只放實現；改行為先改契約再改腳本。

## 命令

```bash
bash tests/next-tick.test.sh                    # 排程語義與間隔解析單測
shellcheck -S error entrypoint.sh build.sh      # 腳本靜態檢查
./build.sh                                      # 本機平台建置 docker-sing-box:dev
./build.sh v1.13.21                             # 指定上游版本
./build.sh --push v1.13.21                      # 全架構建置並推送（驗證用；正式發佈走 CI）
```

## 約定

- 入口腳本是行為契約的實現：拉取 → 變換 → `sing-box check` 校驗 → 原子套用；排程錨定本地 04:00 + n×間隔；任何失敗只記錄、不覆蓋已存設定、不退出容器（子程序意外退出除外）。
- 發佈標籤為 `v*`；`-rN` 修訂後綴只在 git 一側，映像標籤永遠是 `latest` 與 `v{上游}`。
- 行為改動必須同步對應測試；排程邏輯保持在 `next_tick` 純函數裏。
- Windows 開發：`.gitattributes` 強制 LF，勿引入 CRLF；鏡像內已裝 tzdata，勿依賴宿主機時區行為。
- 新腳本入庫時確認可執行位（Windows 上建立的檔案預設不帶）。
