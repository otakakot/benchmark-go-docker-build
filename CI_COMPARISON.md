# CI 実行結果比較

対象: [otakakot/benchmark-go-docker-build](https://github.com/otakakot/benchmark-go-docker-build)  
ワークフロー: Build ([`build.yaml`](.github/workflows/build.yaml))  
実行: 2026-07-20 07:05 UTC 頃  
Run ID: [29723520375](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/29723520375)

## 1. 概要比較

| 項目 | copy-build | multistage-build | multistage-build-gha-only |
|------|------------|------------------|---------------------------|
| ジョブID | 88291377869 | 88291377872 | 88291377901 |
| 結果 | 成功 | 成功 | 成功 |
| 総実行時間（GitHub表示） | 55 秒 | 1分 27 秒 | 1分 25 秒 |
| 総実行時間（ログ計測） | 約 51 秒 | 約 84 秒 | 約 81 秒 |
| ビルド方式 | ホストでGoビルド → Dockerにコピー | マルチステージDocker + BuildKit cache mount + `buildkit-cache-dance` | マルチステージDocker + GHA cacheのみ |
| 使用Dockerfile | [`docker/copy/Dockerfile`](docker/copy/Dockerfile) | [`docker/multistage/Dockerfile`](docker/multistage/Dockerfile) | [`docker/multistage/Dockerfile`](docker/multistage/Dockerfile) |
| Goバージョン | 1.26.5 | 1.26.5 | 1.26.5 |
| ランナー | ubuntu-24.04 | ubuntu-24.04 | ubuntu-24.04 |
| キャッシュ戦略 | `actions/cache` (Go module / build cache) | `actions/cache` + BuildKit cache mount + `cache-from/to type=gha` | `cache-from/to type=gha` のみ |
| キャッシュヒット | なし（初回） | なし（初回） | なし（初回） |
| SBOM/Provenance | 有効 | 有効 | 有効 |

## 2. ステップ別所要時間

| ステップ | copy-build | multistage-build | multistage-build-gha-only |
|----------|------------|------------------|---------------------------|
| Set up job | 1.9 秒 | 1.5 秒 | 1.7 秒 |
| Checkout | 2.5 秒 | 2.8 秒 | 2.7 秒 |
| Set up Go | 0.4 秒 | 1.3 秒 | - |
| Cache restore (Go) | 0.2 秒 | - | - |
| Download Go modules | 1.2 秒 | - | - |
| Build Go binary on host | 0.0 秒 | - | - |
| Set up Docker Buildx | 4.5 秒 | 4.2 秒 | 8.3 秒 |
| Cache Docker cache mounts | - | 0.2 秒 | - |
| Inject Docker cache mounts | - | 0.7 秒 | - |
| Build Docker image | 5.3 秒 | 58.2 秒 | 64.2 秒 |
| Cache save (Go / Docker mount) | 3.4 秒 | 1.5 秒 * | - |
| Post Build Docker image | 0.9 秒 | 0.8 秒 | 1.8 秒 |
| Post Set up Docker Buildx | 0.3 秒 | 1.7 秒 | 1.7 秒 |
| Post Checkout | 0.1 秒 | 0.1 秒 | 0.1 秒 |

\* `multistage-build` の `Cache save` は `Post Cache Docker cache mounts` の時間。

## 3. Docker ビルド内訳

### 3.1 copy-build

| ステップ | 時間 | 備考 |
|----------|------|------|
| ベースイメージ（distroless）の取得 | 約 1.4 秒 | `#9` などで複数レイヤー並列取得 |
| ビルド済みバイナリの `COPY` | 0.1 秒 | `server /bin/server` |
| SBOM生成 | 1.1 秒 | `docker.io/docker/buildkit-syft-scanner:stable-1` |
| Provenance解決 | 0.0 秒 | - |
| **合計（Build Docker image）** | **5.3 秒** | - |

### 3.2 multistage-build

| ステップ | 時間 | 備考 |
|----------|------|------|
| `FROM golang:1.26.5` | 約 9.0 秒 | ベースイメージ取得がボトルネック |
| `WORKDIR /app` | 2.5 秒 | - |
| `go mod download -x` | 1.7 秒 | BuildKit cache mount + `buildkit-cache-dance` により高速化 |
| `go build` | 27.2 秒 | 最も時間を消費 |
| 最終ステージへの `COPY` | 0.0 秒 | - |
| SBOM生成 | 1.0 秒 | - |
| GHA Cacheへのエクスポート | 14.5 秒 | `cache-to type=gha,mode=max` |
| **合計（Build Docker image）** | **58.2 秒** | - |

### 3.3 multistage-build-gha-only

| ステップ | 時間 | 備考 |
|----------|------|------|
| `FROM golang:1.26.5` | 約 9.1 秒 | ベースイメージ取得がボトルネック |
| `WORKDIR /app` | 2.5 秒 | - |
| `go mod download -x` | 1.7 秒 | `cache-from type=gha` からのキャッシュで高速化 |
| `go build` | 28.2 秒 | 最も時間を消費（`multistage-build` より 1 秒遅い） |
| 最終ステージへの `COPY` | 0.0 秒 | - |
| SBOM生成 | 1.0 秒 | - |
| GHA Cacheへのエクスポート | 17.5 秒 | `cache-to type=gha,mode=max`（最も時間がかかる） |
| **合計（Build Docker image）** | **64.2 秒** | - |

## 4. キャッシュ関連

| 項目 | copy-build | multistage-build | multistage-build-gha-only |
|------|------------|------------------|---------------------------|
| キャッシュキー | `go-1.26.5-<hashFiles('go.mod')>` | `docker-1.26.5-<hashFiles('go.mod')>` | なし（GHA cache backend） |
| キャッシュヒット | なし | なし | なし |
| 保存サイズ | 103,152,033 B（約 98.4 MB） | 45,838,094 B（約 43.7 MB） | なし（GHA cache backend経由） |
| 保存速度 | 50.7 MB/s | 55.8 MB/s | - |
| BuildKit cache mount | なし | `cache-dir: cache-mount` | なし（BuildKit cache mountは使用） |

## 5. 主な考察

1. **copy-build が最速（55秒）**
   - ホスト環境でGoビルドを済ませ、Dockerfileはコピーのみなのでビルドが極めて短い。
   - ただし、ホスト環境のセットアップ（Go modulesダウンロード、cache save）が必要。

2. **multistage-build 系はビルドに1分以上かかる**
   - マルチステージビルド内で `go mod download` と `go build` を実行するため、ベースイメージ取得とGoビルドが支配的。
   - `go mod download` は `buildkit-cache-dance` または `cache-from type=gha` のおかげで 1.7 秒と高速。
   - `go build` は約 27〜28 秒で、Docker内ビルドのオーバーヘッドが主なボトルネック。

3. **GHA cacheのエクスポートが無視できない時間**
   - `cache-to type=gha,mode=max` の書き出しに `multistage-build` で 14.5 秒、`multistage-build-gha-only` で 17.5 秒を消費。
   - 次回以降のビルドで `cache-from` から復元されればこの時間は短縮される可能性がある。

4. **buildkit-cache-dance vs GHA cache-only**
   - 今回の初回実行では、どちらの手法も `go mod download` は同じくらいの速度（1.7秒）となった。
   - `multistage-build`（buildkit-cache-dance）の方が、GHA cacheエクスポートが 3 秒短く、総時間も約 2 秒短い。
   - ただし、buildkit-cache-dance の分、ワークフローが複雑になり、追加の `Inject`/`Post Cache` ステップが必要。

5. **Set up Docker Buildx の時間差**
   - `multistage-build-gha-only`（8.3秒）が他よりも長い。これは並列実行時のランナー負荷やネットワークの揺れの可能性がある。

## 6. 結論

- **最速のビルド**: `copy-build`（55秒）
- **再利用性・再現性を重視する場合**: `multistage-build` または `multistage-build-gha-only` を検討。
- **2回目以降の実行**で `go mod download` / `go build` のキャッシュが効いてくるかが重要。初回実行では `copy-build` が圧倒的に速いが、キャッシュヒット時の差を見るための再実行も有用。

## 補足

- 本比較は初回実行（キャッシュミス）時の結果である。
- Dockerイメージの最終サイズはログから直接読み取れなかった。必要であれば、ビルド後に `docker images` や `docker image inspect` を実行するステップを追加するとよい。
- SBOM・Provenance は全ジョブで有効化されており、BuildKitのSyft scannerにより生成されている。
