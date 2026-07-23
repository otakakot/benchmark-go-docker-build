# Go Docker Build 戦略比較レポート（最終版）

## 検証条件

- **4 戦略** を同一ワークフロー内で並列実行
- **12 回** の実行（3条件 × 3-6回）
- ランナー: ubuntu-latest（24.04）

### 比較した 4 戦略

| # | 戦略 | Dockerfile | キャッシュ機構 |
|---|---|---|---|
| 1 | **copy-build** | `docker/copy/Dockerfile`（FROM distroless + COPY） | Go バイナリをホスト上でビルドし、Docker は COPY のみ。Go ビルドキャッシュは `actions/cache` で管理 |
| 2 | **multistage-build** | `docker/multistage/Dockerfile`（FROM golang AS build + go build） | なし。`--mount=type=cache` で同一ジョブ内のキャッシュのみ有効 |
| 3 | **multistage-build-cache** | 同上 | `cache-from/ cache-to: type=gha,mode=max` で Docker レイヤーを GHA cache に保存 |
| 4 | **multistage-build-cache-dance** | 同上 | 上記 + `buildkit-cache-dance` で `--mount=type=cache` の中身も GHA cache で永続化 |

### 実行条件

| 条件 | branch | 変更内容 | 実行回数 | Run ID |
|---|---|---|---|---|
| A. main（初回 warm up） | main | なし | Run1-6（6回） | [30013709780](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30013709780) 他 |
| B. feature branch（main.go のみ変更） | api1, api2, api3 | main.go に API 追加 | Run7-9（3回） | [30019573820](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30019573820) 他 |
| C. go.mod 変更 | mod1, mod2, mod3 | 依存モジュール追加 | Run10-12（3回） | [30020153217](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30020153217) 他 |

### 実行結果の取得元

表記されている所要時間は、各 GitHub Actions ジョブの `startedAt` から `completedAt` までの wall-clock 時間（秒）です。

| Run | 条件 | branch | Run ID |
|---|---|---|---|
| Run1 | A. main | main | [30013709780](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30013709780) |
| Run2 | A. main | main | [30016631157](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30016631157) |
| Run3 | A. main | main | [30017114766](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30017114766) |
| Run4 | A. main | main | [30018995893](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30018995893) |
| Run5 | A. main | main | [30019124060](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30019124060) |
| Run6 | A. main | main | [30019362434](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30019362434) |
| Run7 | B. feature branch | api1 | [30019573820](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30019573820) |
| Run8 | B. feature branch | api2 | [30019732312](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30019732312) |
| Run9 | B. feature branch | api3 | [30019883881](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30019883881) |
| Run10 | C. go.mod 変更 | mod1 | [30020153217](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30020153217) |
| Run11 | C. go.mod 変更 | mod2 | [30020426769](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30020426769) |
| Run12 | C. go.mod 変更 | mod3 | [30020636276](https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30020636276) |

---

## 結果

### A. main ブランチ（変更なし, 6回）

| 戦略 | cold | Run2 | Run3 | Run4 | Run5 | Run6 | warm 平均 |
|---|---|---|---|---|---|---|---|
| **multistage-build-cache** 🥇 | 102s | 72s | 74s | **17s** | **23s** | **18s** | **19.3s** |
| **copy-build** 🥈 | 55s | 65s | 56s | 32s | **19s** | 31s | 27.3s |
| cache-dance 🥉 | 137s | 110s | 101s | 50s | 30s | 35s | **38.3s** |
| multistage-build | 64s | 65s | 54s | 55s | 60s | 63s | **59.3s** |

- **Run1-3** はキャッシュがない状態（cold）。Run4-6 はキャッシュが蓄積された状態（warm）
- **cold** 列は Run1（初回）を示す
- **warm 平均** はキャッシュが十分に効いた Run4-6 の平均
- multistage-build はキャッシュ機構を持たず、常に 54-65s で安定

### B. feature branch（main.go 変更, 3回）

| 戦略 | api1 | api2 | api3 | 平均 |
|---|---|---|---|---|
| **copy-build** 🥇 | **35s** | **37s** | **27s** | **33.0s** |
| multistage-build-cache 🥈 | 58s | 56s | 74s | 62.7s |
| cache-dance 🥉 | 53s | 52s | 82s | 62.3s |
| multistage-build | 67s | 58s | 60s | 61.7s |

- ブランチが変わるため GHA cache（`type=gha`）は引き継がれない
- `actions/cache` は default branch（main）のキャッシュに fallback するため、copy-build のみ恩恵を受けられる

### C. go.mod 変更（3回）

| 戦略 | mod1 | mod2 | mod3 | 平均 |
|---|---|---|---|---|
| **copy-build** 🥇 | **19s** | **24s** | **31s** | **24.7s** |
| multistage-build 🥈 | 56s | 59s | 56s | 57.0s |
| multistage-build-cache 🥉 | 79s | 74s | 77s | 76.7s |
| cache-dance | 94s | 100s | 94s | 96.0s |

- copy-build は `restore-keys: go-1.26.5-` で古いキャッシュに fallback HIT、Go build が 1-4s で完了

---

## 戦略別分析

### copy-build（推奨）

**仕組み**:
```
go build on host (1-4s) → docker build (COPYのみ, 5-7s)
```

**全条件でのパフォーマンス**: 19-55s（warm 状態では 19-37s）

**なぜ速いか**:
1. Go ビルドをホスト上で行い、`actions/cache` でキャッシュ管理 → 差分ビルドのみ（1-4s）
2. Docker は COPY のみの最小 Dockerfile → ビルド 5-7s。SBOM 含めても軽量
3. `actions/cache` の `restore-keys` により default branch のキャッシュに fallback → feature branch でも恩恵
4. GHA cache への export がない → オーバーヘッドゼロ

**注意点**:
- ホスト上で `CGO_ENABLED=0 GOOS=linux GOARCH=amd64` のクロスコンパイルが必要
- Dockerfile が 3行とシンプルだが、ホスト上の Go ツールチェーンに依存

### multistage-build-cache（main 最速）

**仕組み**:
```
Docker build with GHA cache (全レイヤー CACHED + export 1-2s)
```

**main での warm 平均**: 19s（最速）

**なぜ速い（main 限定）**:
- Docker レイヤーが全 CACHED 状態になると、実質 GHA cache export の 1-2s のみ
- `golang:1.26.5` ベースイメージもキャッシュされる

**なぜ遅い（main 以外）**:
- `cache-from: type=gha` はブランチスコープ → feature branch では完全な cold start（54-74s）
- cold start は 102s と全戦略中最悪
- `--mount=type=cache` を使用しているため、レイヤーキャッシュだけでは Go ビルド再実行を避けられない

### multistage-build-cache-dance

**仕組み**: 上記 + buildkit-cache-dance による `--mount=type=cache` の中身の永続化

```yaml
key: docker-${{ steps.setup-go.outputs.go-version }}-${{ hashFiles('go.mod') }}
restore-keys: |
  docker-${{ steps.setup-go.outputs.go-version }}-
  docker-
```

**平均**: main 38s / feature 62s / go.mod 変更 96s

**go.mod 変更時の実態（mod1）**:

cache-dance の `docker-` キャッシュは `restore-keys` により main のキャッシュが HIT している。**キャッシュ自体は使われている。**

```
Cache hit for restore-key: docker-1.26.5-0bfbe49...  ← main のキャッシュに HIT
Cache restored from key: docker-1.26.5-0bfbe49...   ← 復元成功
```

しかし全体の所要時間は main warm の 30-50s に対し 94-100s と大幅に悪化する。内訳は以下の通り:

```
mod1 cache-dance 内訳:
  ┌──────────────────────────────────────────────┐
  │  actions/cache restore（docker- キャッシュ） 4s│ ← main のキャッシュ HIT
  │  buildkit-cache-dance inject                 8s│
  ├──────────────────────────────────────────────┤
  │  Docker build                                 │
  │    #16 WORKDIR /app           CACHED        │ ← ベースイメージはCACHED
  │    #17 go mod download            3s         │ ← 新モジュールのみDL（差分）
  │    #18 go build                   1s         │ ← 一部再コンパイル（差分）
  │    #21 GHA cache export           8s         │ ← 新ブランチ＝cache MISS → 全量export
  │    その他（context転送等）       ~25s         │
  ├──────────────────────────────────────────────┤
  │  buildkit-cache-dance extract    26s         │ ← キャッシュ更新あり → 全量抽出
  │  actions/cache save               4s         │
  ├──────────────────────────────────────────────┤
  │  合計                            ~96s         │
  └──────────────────────────────────────────────┘
```

**なぜ main warm より遅いか**:

| 項目 | main (warm) | go.mod 変更 |
|---|---|---|
| GHA cache import | HIT（全レイヤー CACHED） | MISS（新ブランチのため） |
| GHA cache export | 1s（index のみ） | **8s**（全レイヤーを新規保存） |
| go mod download | 0s（CACHED） | **3s**（新モジュールあり） |
| go build | 0s（CACHED） | **1s**（一部再コンパイル） |
| cache-dance extract | 0s（skip-extraction） | **26s**（cache mount 更新あり → 全量抽出） |

**ボトルネックの本質**:

cache-dance は cache mount に部分的な更新があると「更新あり」と判定しやすく、**その場合に全量抽出が発生する**。go.mod 変更により Go のモジュール/ビルドキャッシュが一部更新されると、そのトリガーで ~26s の抽出処理が走る。

加えて GHA cache（`cache-from: type=gha`）がブランチスコープのため、新ブランチでは常に cache MISS となり 8s の export が発生する。この **cache-dance 抽出（26s）+ GHA cache export（8s）の二重オーバーヘッド** が、copy-build が 25s で終わる処理を 96s に引き延ばしている。

**結論**: cache-dance の `docker-` キャッシュ自体は使用されているものの、その恩恵（go build の 1s）よりも、二重のキャッシュ保存コストの方が圧倒的に大きい。

### multistage-build（ベースライン）

**仕組み**: `--mount=type=cache` のみ。ジョブ跨ぎのキャッシュ永続化はなし

**平均**: 59s（全条件で安定）

毎回同じ 55-65s。Docker の `--mount=type=cache` が BuildKit のキャッシュを利用するが、毎回新しい BuildKit コンテナなので常にフルビルド。

---

## 総合成績

| 順位 | 戦略 | main (warm) | feature branch | go.mod 変更 | 総合評価 |
|---|---|---|---|---|---|
| 🥇 | **copy-build** | 27s | **33s** | **25s** | **warm 時は 30秒以内** |
| 🥈 | **multistage-build-cache** | **19s** | 62s | 77s | main 最速だが汎用性に欠ける |
| 🥉 | cache-dance | 38s | 62s | 96s | 複雑な割に中途半端 |
| 4 | multistage-build | 59s | 62s | 57s | 安定してるが改善余地なし |

---

## 推奨

**実運用では `copy-build` 一択。**

理由:
1. warm 状態ではすべてのブランチ・変更パターンで安定的に 25-37s
2. `actions/cache` の `restore-keys` が default branch に fallback するため、feature branch でも Go ビルドキャッシュが効く
3. Docker build が COPY のみで単純。`cache-from/ cache-to: type=gha` は不要（レイヤーが1層のため）
4. cold start も 55s と 4戦略中最速

### 改善案

現在の `copy-build` でも実用十分だが、以下の点を改善できる:

```yaml
- name: Cache Go modules and build cache
  uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
  with:
    path: |
      ~/.cache/go-build
      ~/go/pkg/mod
    key: go-${{ steps.setup-go.outputs.go-version }}-${{ hashFiles('go.mod') }}
    restore-keys: |
      go-${{ steps.setup-go.outputs.go-version }}-

- run: CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s" -trimpath -o server .

- name: Build Docker image
  uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a # v7.3.0
  with:
    context: .
    file: docker/copy/Dockerfile
    push: false
    sbom: true
    provenance: true
```

**変更点**:
- `actions/cache/restore` + `save` の分割 → 1つの `actions/cache` に統合（シンプル化。シンプルなケースでは統合版が推奨される）

---

## 補足: キャッシュスコープの違い

| キャッシュ種別 | コンポーネント | スコープ | feature branch での動作 |
|---|---|---|---|
| `actions/cache` | Go ビルド/モジュールキャッシュ | ブランチ（default branch fallback あり） | ✅ main のキャッシュを `restore-keys` で利用可能 |
| `cache-from: type=gha` | Docker レイヤーキャッシュ | ブランチのみ（fallback なし） | ❌ 新ブランチでは完全に無効 |

この差が feature branch でのパフォーマンスに直結している。
