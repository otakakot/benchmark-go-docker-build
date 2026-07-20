# CI ログ比較: benchmark-go-docker-build ビルド戦略比較レポート

## 対象ワークフロー

| 実行 | ブランチ | go.mod | Run ID | リンク |
|---|---|---|---|---|
| main 初回 | `main` | 不変 | 29723889159 | [Build #29723889159](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/29723889159) |
| PR api 1回目 | `api` | 不変 | 29724437996 | [Build #29724437996](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/29724437996) |
| PR api 2回目 | `api` | 不変 | 29724894724 | [Build #29724894724](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/29724894724) |
| PR module | `module` | 変更 | 29725337889 | [Build #29725337889](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/29725337889) |

## 1. 総時間推移

| ジョブ | main 初回 | PR api 1回目 | PR api 2回目 | PR module（go.mod 変更） |
|---|---:|---:|---:|---:|
| copy-build | 57s | 28s | 34s | 37s |
| multistage-build | 71s | 80s | 58s | 81s |
| multistage-build-cache-dance | 101s | 70s | 68s | 103s |

## 2. ジョブ別詳細比較

### 2.1 copy-build

| ステップ | main | PR api 1回目 | PR api 2回目 | PR module |
|---|---:|---:|---:|---:|
| Set up job | 2s | 1s | 4s | 2s |
| Checkout | 2s | 1s | 1s | 3s |
| Set up Go | 1s | 1s | 1s | 1s |
| actions/cache restore | 0s | 3s | 3s | 5s |
| Download Go modules | 2s | 0s | 0s | 1s |
| Build Go binary on host | 33s | 2s | 3s | 5s |
| Set up Docker Buildx | 4s | 7s | 10s | 5s |
| Build Docker image | 5s | 6s | 7s | 7s |
| actions/cache save | 3s | 0s | 0s | 0s |
| Post Build Docker image | 1s | 2s | 1s | 2s |
| Post Set up Docker Buildx | 1s | 0s | 1s | 0s |
| Post Set up Go | 0s | 0s | 0s | 1s |
| Post Checkout | 0s | 1s | 0s | 0s |

### 2.2 multistage-build

| ステップ | main | PR api 1回目 | PR api 2回目 | PR module |
|---|---:|---:|---:|---:|
| Set up job | 1s | 1s | 1s | 2s |
| Checkout | 3s | 1s | 1s | 2s |
| Set up Docker Buildx | 3s | 9s | 4s | 5s |
| Build Docker image | 58s | 62s | 46s | 64s |
| Post Build Docker image | 2s | 2s | 1s | 2s |
| Post Set up Docker Buildx | 1s | 2s | 2s | 2s |
| Post Checkout | 1s | 0s | 0s | 0s |

### 2.3 multistage-build-cache-dance

| ステップ | main | PR api 1回目 | PR api 2回目 | PR module |
|---|---:|---:|---:|---:|
| Set up job | 2s | 3s | 3s | 4s |
| Checkout | 3s | 1s | 1s | 3s |
| Set up Go | 1s | 1s | 1s | 0s |
| Set up Docker Buildx | 5s | 8s | 5s | 9s |
| Cache Docker cache mounts | 0s | 4s | 3s | 2s |
| Inject Docker cache mounts | 2s | 8s | 9s | 15s |
| Build Docker image | 54s | 36s | 37s | 32s |
| Post Build Docker image | 2s | 2s | 2s | 2s |
| Post Inject Docker cache mounts | 24s | 0s | 0s | 28s |
| Post Cache Docker cache mounts | 3s | 0s | 0s | 3s |
| Post Set up Docker Buildx | 2s | 3s | 3s | 2s |
| Post Set up Go | 1s | 0s | 0s | 0s |
| Post Checkout | 0s | 0s | 0s | 0s |

## 3. Docker ビルド内部時間（multistage 系）

| 操作 | main | PR api 1回目 | PR api 2回目 | PR module |
|---|---:|---:|---:|---:|
| multistage-build: WORKDIR | 2.6s | CACHED | CACHED | 15.7s |
| multistage-build: go mod download | 1.9s | 18.6s | 10.2s (CACHED) | 4.4s |
| multistage-build: go build | 26.4s | 28.6s | 28.4s | 28.3s |
| multistage-build: gha cache export | 14.5s | 6.2s | 2.7s | 7.8s |
| cache-dance: WORKDIR | 2.5s | CACHED | CACHED | 10.5s |
| cache-dance: go mod download | 3.0s | 15.4s | 16.6s (CACHED) | 7.2s |
| cache-dance: go build | 26.7s | 3.4s | 3.5s | 1.1s |
| cache-dance: gha cache export | 9.8s | 6.1s | 7.0s | 4.8s |

## 4. キャッシュ動作

| ジョブ | main | PR api 1回目 | PR api 2回目 | PR module |
|---|---|---|---|---|
| copy-build | ミス（保存 ~98MB） | ヒット（~98MB） | ヒット（~98MB） | restore-key フォールバック → 部分ヒット |
| multistage-build | gha import（ヒットなし） | gha import（WORKDIR のみ） | gha import（WORKDIR + go mod download） | gha import（ヒットなし、go.mod 変更のため） |
| cache-dance | ミス（保存 ~98MB） | ヒット（~98MB、skip-extract） | ヒット（~98MB、skip-extract） | restore-key フォールバック → 旧キャッシュ注入 + 新規保存 ~104MB |

## 5. その他指標

| ジョブ | main | PR api 1回目 | PR api 2回目 | PR module |
|---|---|---|---|---|
| copy-build アーティファクト | 32.75 KB | 33.79 KB | 33.72 KB | 33.41 KB |
| multistage-build アーティファクト | 66.46 KB | 53.63 KB | 52.99 KB | 57.67 KB |
| cache-dance アーティファクト | 62.94 KB | 52.1 KB | 51.9 KB | 52.3 KB |
| cache-dance 警告 | なし | EACCES 権限エラー | EACCES 権限エラー | EACCES 権限エラー（rmdir） |

## 6. 考察

### 6.1 go.mod 変更時の挙動

- **copy-build**: 新しい go.mod の hash に一致するキャッシュはないが、`restore-keys` のプレフィックス一致で旧キャッシュを復元。`Download Go modules`（1s）と `Build Go binary`（5s）で差分を更新。総時間は 37s と依然として高速。
- **multistage-build**: go.mod 変更により gha cache のレイヤーキャッシュが無効化。`go mod download`（4.4s）は比較的速いが、`go build`（28.3s）は再実行。総時間 81s と初回 PR 実行（80s）と同等。
- **cache-dance**: 新しい key で primary cache miss となったが、`restore-keys` で旧 cache mount を復元。その後ビルドで go mod download（7.2s）と go build（1.1s）を実施し、Post 処理で新しい key に保存（~104MB）。Inject/Extract のオーバーヘッド（15s + 28s + 3s）が大きく、総時間 103s と最長。

### 6.2 各戦略の特徴

- **copy-build（ホストビルド + actions/cache）**: go.mod 変更時も `restore-keys` によるフォールバックが効き、最も安定して高速（28〜37s）。実装も最もシンプル。
- **multistage-build（gha cache）**: go.mod 変更時はほぼ再実行（81s）。gha cache はレイヤー単位で、cache mount の内容は永続化されない。2 回目以降の同じ go.mod では go mod download がキャッシュされるが、go build はソース変更で無効化。
- **cache-dance（buildkit-cache-dance + actions/cache）**: go.mod 変更時でも旧 cache mount のフォールバックにより go build が 1.1s と劇的に短縮される。ただし、primary key miss 時は Inject/Extract/Save のフルオーバーヘッド（46s 程度）が発生し、総時間は悪化。継続的に同じ go.mod を使う場合に真価を発揮。

### 6.3 注意点

- cache-dance の Inject/Extract ステップで、Go モジュールキャッシュ内の read-only ファイル/ディレクトリに対する `EACCES: permission denied` 警告が継続。buildkit-cache-dance v3.4.0 の既知の挙動と思われるが、現状では致命的ではない。
- cache-dance は primary key hit 時（skip-extraction=true）に最も効率が良く（70s 前後）、primary key miss 時は旧キャッシュの抽出・新規保存が入るため遅延（103s）。

### 6.4 結論

- **最も推奨**: copy-build。go.mod 変更時も安定して 30s 台前半。
- **Docker 内ビルドが必須で、go.mod は頻繁に変わらない**: multistage-build + gha cache で 58s 程度まで短縮可能。
- **Docker 内ビルドが必須で、ビルドキャッシュを最大限活かしたい**: cache-dance が有効だが、go.mod 変更時のオーバーヘッドとパーミッション警告を受け入れる必要がある。同じ go.mod で継続的に実行する場合に最適。
