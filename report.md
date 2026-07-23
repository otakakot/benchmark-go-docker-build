# Go Docker Build 戦略比較レポート

## 実行結果サマリ

### ジョブ合計時間（全3回の平均）

| 戦略 | Run 1 (cold) | Run 2 (warm) | Run 3 (warm) | 平均 |
|---|---|---|---|---|
| **copy-build** | **55s 🥇** | 65s 🥇 | **56s 🥈** | **58.7s 🥇** |
| **multistage-build** | 64s 🥈 | **65s 🥇** | **54s 🥇** | **61.0s 🥇** |
| multistage-build-cache | 102s | 72s | 74s | 82.7s |
| multistage-build-cache-dance | 137s | 110s | 101s | 116.0s |

### Docker Build ステップ所要時間（内訳）

| 戦略 | Run 1 (cold) | Run 2 | Run 3 |
|---|---|---|---|
| **copy-build** (Go build on host) | 27s | 34s | 28s |
| **copy-build** (Docker COPY) | 6s | 7s | 7s |
| **multistage-build** (Docker build) | 47s | 45s | 42s |
| **multistage-build-cache** (Docker build) | 84s | 59s | 60s |
| **multistage-build-cache-dance** (Docker build) | 76s | 63s | 56s |

---

## 戦略ごとの内訳と分析

### 1. copy-build

**仕組み**: Go バイナリを GitHub Actions ランナーのホスト上で直接ビルド → 最小の Dockerfile（COPY のみ）でイメージ化

```
go build on host (27-34s) → docker build with COPY (6-7s)
```

**分析**:
- `go build` 自体は `multistage-build` の Docker 内ビルドと同等の時間（25-34s）。CGO_ENABLED=0 かつ GOOS=linux GOARCH=amd64 のクロスコンパイル。
- Docker ビルドは `docker/copy/Dockerfile`（FROM distroless + COPY server + ENTRYPOINT の3行）であり、レイヤーが1つしかないため SBOM 含めても 6-7s で完了。
- `actions/cache` による Go のビルドキャッシュ保存が行われているが、**後続の Run ではキャッシュが見つからず都度フルビルド**している（後述）。

**なぜ速いか**:
1. Docker ビルドが COPY のみで圧倒的に軽い（SBOM 含め 1-2s、残りは Buildx セットアップ）→ **Docker デーモンのオーバーヘッドが最小限**
2. Go の依存解決・ビルドがホスト上のネイティブ環境で実行される

**なぜ遅くなりうるか**:
- Go ビルドキャッシュが効いていない（cache miss）ため、毎回フルビルド。本来キャッシュが効けば Go build は 5-10s まで短縮されるはず。

---

### 2. multistage-build（プレーンなマルチステージビルド）

**仕組み**: Docker マルチステージビルド、キャッシュ機構は `--mount=type=cache` のみ

```
Dockerfile:
  FROM golang:1.26.5 AS build
    go mod download (--mount=type=cache)
    go build      (--mount=type=cache)
  FROM distroless
    COPY --from=build /bin/server /bin/
```

**分析**:
- Docker build 内部での `go build` ステップは **26.9s**（Run 2）／ **25.8s**（Run 3）。
- `--mount=type=cache` により Go モジュールキャッシュとビルドキャッシュが BuildKit 内で保持されるが、**ジョブごとに新しいランナー + 新しい BuildKit コンテナ** なのでキャッシュは引き継がれない → 毎回フルビルド。
- SBOM 生成が約 1s。
- GHA cache へのエクスポートがないため、ビルド完了後すぐに終了する。

**なぜ速いか**:
1. キャッシュエクスポート/インポートのオーバーヘッドがゼロ
2. Dockerfile 自体がシンプルでレイヤー構造がフラット
3. `--mount=type=cache` による BuildKit 内キャッシュは同一ジョブ内では有効

**なぜ遅くなりうるか**:
- `golang:1.26.5` ベースイメージのプル（Run 1 では 1.6s、Run 2/3 ではキャッシュ済みで 0.3s）
- Docker のレイヤー構造と SBOM 生成による若干のオーバーヘッド

---

### 3. multistage-build-cache（GHA cache利用）

**仕組み**: `multistage-build` に `cache-from/ cache-to: type=gha` を追加

```yaml
cache-from: type=gha
cache-to: type=gha,mode=max
```

**分析**:

**Run 1 (cold) - 84s**:
- GHA cache からのインポート（初回は cache miss だがチェックに時間）
- ビルド（Go の依存解決 + ビルド）
- **GHA cache へのエクスポートに 15-19s**

**Run 2/3 (warm) - 59-60s**:
- GHA cache からのインポートが発生（キャッシュヒット）
- ビルド時間そのものは `multistage-build` と同等（約 27s）
- **GHA cache へのエクスポートに 15.1-15.8s** ← ボトルネック

**なぜ遅いか（ボトルネック詳細）**:

| フェーズ | 時間 | 備考 |
|---|---|---|
| ビルド本体（Go のコンパイルなど） | ~27s | multistage-build と同じ |
| GHA cache エクスポート | **15-16s** | `exporting to GitHub Actions Cache` |
| 前処理（メタデータロードなど） | ~5s | |
| 後処理（SBOM, 証明書） | ~1s | |

**GHA cache エクスポートの内訳**:
- `mode=max` により全レイヤーを GHA cache に保存
- マルチステージビルドの中間レイヤー（golang ベースイメージ層など）を圧縮・アップロード
- 約 15s の純粋なネットワーク転送 + 圧縮時間

**結論**: GHA cache のエクスポートがボトルネックであり、キャッシュヒットによるビルド時間短縮を上回るオーバーヘッドを生んでいる。

---

### 4. multistage-build-cache-dance（buildkit-cache-dance）

**仕組み**: 上記に加え、`buildkit-cache-dance` で `--mount=type=cache` の中身も GHA cache で永続化

```yaml
- uses: actions/cache@v6        # 事前にキャッシュマウントの内容を復元
- uses: reproducible-containers/buildkit-cache-dance@v3  # キャッシュ注入
- uses: docker/build-push-action@v7  # ビルド（cache-from/ cache-to: type=gha）
  # ↑ さらに Post フェーズで cache-dance がキャッシュマウントを抽出・保存
```

**分析**:

| フェーズ | 時間（Run 2） | 備考 |
|---|---|---|
| actions/cache 復元 | ~1s | ほぼ即時（ただし cache miss） |
| buildkit-cache-dance inject | ~1s | |
| Docker build（本体） | 26.4s | Go build |
| GHA cache エクスポート | **19.0s** | `exporting to GitHub Actions Cache` |
| buildkit-cache-dance extract | ~23s | Post フェーズでのキャッシュ抽出 |
| actions/cache 保存 | ~4s | Post フェーズ |

**なぜ最も遅いか**:
1. Docker build の GHA cache エクスポート（19s） ← multistage-build-cache と同じ問題
2. buildkit-cache-dance の **Post 抽出処理が約 23s** 追加
   - BuildKit コンテナから `/go/pkg/mod/` と `/root/.cache/go-build` を抽出・圧縮
3. さらに actions/cache への保存もあり（4s）

**cache-dance 本来の目的**: `--mount=type=cache` の中身をジョブ間で永続化することで、2回目以降の Go ビルドを高速化する。しかし:
- キャッシュ注入や抽出のオーバーヘッドが大きすぎる
- 今回のワークロードでは Go モジュールの変更がないため、`--mount=type=cache` が本来もたらす恩恵が少ない
- GHA cache export とも競合して二重にキャッシュ保存が発生

---

## 根本原因の総括

### なぜ GHA cache が逆効果なのか

`multistage-build-cache` と `multistage-build-cache-dance` が素の `multistage-build` より遅い理由:

```
multistage-build-cache の実態:
  ┌──────────────────────────────────────────┐
  │  ビルド本体 (go build)          ~27s     │
  │  GHA cache エクスポート         ~15s     │ ← 純粋なオーバーヘッド
  │  SBOM/証明書                    ~1s      │
  ├──────────────────────────────────────────┤
  │  合計                          ~43s      │
  └──────────────────────────────────────────┘
  
  素の multistage-build:
  ┌──────────────────────────────────────────┐
  │  ビルド本体 (go build)          ~27s     │ ← 同じ
  │  SBOM/証明書                    ~1s      │
  ├──────────────────────────────────────────┤
  │  合計                          ~28s      │
  └──────────────────────────────────────────┘
```

GHA cache (`type=gha`) は**ビルド結果の全レイヤー**をキャッシュする。しかし今回の Dockerfile の中間層は `--mount=type=cache` を使用しているため、レイヤーキャッシュだけでは Go のビルドキャッシュが保持されない。結果として:
- **キャッシュがあっても Go ビルドは必ず再実行される**（毎回 27s）
- その上で全レイヤーのエクスポート（15s）が走る

つまり **GHA cache のコストだけが乗ってメリットがない**。

### cache-dance が抱える二重のオーバーヘッド

cache-dance は `--mount=type=cache` の中身を GHA の汎用 cache で保存するが、それに加えて GHA cache export も有効になっている（`cache-from/ cache-to: type=gha`）。以下の二重保存が発生:

1. Docker build → GHA cache export（レイヤーキャッシュ）→ **15s**
2. Post 処理 → cache-dance extract → actions/cache save（cache-mount の中身）→ **27s**

```
cache-dance のコスト内訳:
  ┌──────────────────────────────────────────┐
  │  Docker build (go build)        ~27s     │
  │  GHA cache export (layers)     ~19s      │ ← 1つ目のオーバーヘッド
  │  cache-dance extract           ~23s      │ ← 2つ目のオーバーヘッド
  │  actions/cache save            ~4s       │
  ├──────────────────────────────────────────┤
  │  ビルド以外のオーバーヘッド合計 ~46s      │
  └──────────────────────────────────────────┘
```

### copy-build で Go cache が効いていない問題（注意: 人為的削除による）

`actions/cache` による Go のビルドキャッシュ保存は行われている（Run 1, 2 ともに保存ログあり）が、後続の Run で復元できていない:

```
Run 1:  Cache saved    → key: go-1.26.5-0bfbe...
Run 2:  Cache NOT found ← 同じキーで検索
Run 2:  Cache saved    → key: go-1.26.5-0bfbe...
Run 3:  Cache NOT found ← 同じキーで検索
```

これは **検証目的で人為的にキャッシュが削除されていた** ためであり、GitHub Actions のキャッシュ機構に問題があるわけではない。

そのため、**Go ビルドキャッシュが正しく永続化されるかは未検証の状態** である。現在の保存/復元の実装は `actions/cache/restore` と `actions/cache/save` を別々のステップに分けているが、これは既知のバグを踏む可能性がある。後述の修正で結合アクションに統一すれば Go ビルドキャッシュが次回以降にヒットし、`go build` が **5-10s まで短縮**、ジョブ合計は **~25-30s** まで削減できる見込み。

---

## 結論と推奨

### パフォーマンス順位

| 順位 | 戦略 | 平均時間 | 評価 |
|---|---|---|---|
| 🥇 | copy-build | 58.7s | シンプルで安定、Docker レイヤーが最小 |
| 🥇 | multistage-build | 61.0s | キャッシュ不要で手軽、同程度の速度 |
| ❌ | multistage-build-cache | 82.7s | GHA cache export が逆効果 |
| ❌ | multistage-build-cache-dance | 116.0s | 二重のオーバーヘッドで最遅 |

**補足**: 上記の修正は `actions/cache/restore` + `actions/cache/save` の分割パターンが GitHub Actions のキャッシュ不変性（immutable keys）と相性が悪いという既知の問題への対策である。`actions/cache` の結合アクション（1つの step で restore と save を兼ねる）に変更することで、以下の問題を回避する:
- save 時に同一キーが存在すると失敗する（がログには "Cache saved" と出る）
- 別ステップだと `cache-primary-key` の出力が想定と異なる値になるケースがある

### 推奨: ハイブリッド戦略

このワークロードでは以下の点を考慮すると:

- `--mount=type=cache` は同一 BuildKit 内でのみ有効。ジョブ跨ぎでは無意味。
- GHA cache (`type=gha`) のレイヤーエクスポートは純粋なオーバーヘッド。
- Docker Image の最終成果物は軽量 distroless + バイナリ1つ。

**推奨パターン: `copy-build` の Go ビルドキャッシュ問題を解決する**

```yaml
- uses: actions/cache/restore@v6
  id: cache
  with:
    path: |
      ~/.cache/go-build
      ~/go/pkg/mod
    key: go-cache-${{ hashFiles('go.mod') }}-${{ runner.os }}

- run: CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s" -trimpath -o server .

- name: Build Docker image
  uses: docker/build-push-action@v7
  with:
    context: .
    file: docker/copy/Dockerfile
    # cache-from/ cache-to: type=gha は不要（レイヤーが1つしかない）

- uses: actions/cache/save@v6
  if: steps.cache.outputs.cache-hit != 'true'
  with:
    path: |
      ~/.cache/go-build
      ~/go/pkg/mod
    key: go-cache-${{ hashFiles('go.mod') }}-${{ runner.os }}
```

**改善点**:
1. Go ビルドキャッシュのキーを `runner.os` を含めてユニーク化し、キャッシュ競合を回避
2. Docker build に `cache-from/ cache-to: type=gha` を指定しない（レイヤーが 1 層のみなので不要）
3. `actions/cache` が復元できれば Go build が 5-10s に短縮 → ジョブ合計 **~25-30s** が期待値
