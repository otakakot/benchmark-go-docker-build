# ローカルベンチマーク: multistage / copy / ko

`docker/multistage/Dockerfile`・`docker/copy/Dockerfile`・`ko` の 3 方式で
同一アプリのコンテナイメージを生成し、所要時間と成果物を比較した。

再現用スクリプト: [`scripts/benchmark.sh`](scripts/benchmark.sh)

```sh
RUNS=5 scripts/benchmark.sh cold warm change   # これを 2 回実行して n=10 を得た
```

計測対象の Dockerfile は以下の構成（ビルダー = alpine、ランタイムベース = ko と同一の
`cgr.dev/chainguard/static` に digest 固定）。

| | ビルダーイメージ | ランタイムベース |
|---|---|---|
| multistage | `golang:1.26.5-alpine` | `cgr.dev/chainguard/static`（digest 固定） |
| copy | （ホストの Go 1.26.5） | `cgr.dev/chainguard/static`（digest 固定） |
| ko | （ホストの Go 1.26.5） | `cgr.dev/chainguard/static`（ko のデフォルト） |

## 実行環境

| 項目 | 値 |
|---|---|
| ホスト | macOS (darwin/arm64, Apple Silicon) |
| Docker | Server 29.4.0 / buildx 0.33.0 (OrbStack) |
| ko | 0.19.1 |
| Go | 1.26.5 |
| ターゲット | `linux/arm64`（ホストと同一、エミュレーションなし） |
| 試行回数 | 各シナリオ **10 回**（5 回 × 2 ブロック、約 2 時間の間隔を空けて実施） |

## 計測方法

3 方式が同じ土俵に立つように、以下を揃えている。

- **出力先を統一**: 3 方式とも「ローカル docker デーモンにイメージをロード」まで。
  - multistage / copy: `docker buildx build --load`（専用 `docker-container` builder）
  - ko: `KO_DOCKER_REPO=ko.local/bench ko build --bare`
- **キャッシュを隔離**: `GOCACHE` / `GOMODCACHE` / `KOCACHE` をベンチ専用ディレクトリに、
  BuildKit は専用 builder に隔離。ホストのグローバルキャッシュは一切汚さない。
- **ビルドコンテキストを統一**: `server` バイナリは copy 方式の生成物なので、
  各計測の直前に削除する（multistage の `--mount=type=bind,target=.` が
  無関係なファイルを転送してしまうため）。
- **copy 方式は前段の Go ビルドも計測に含む**
  （`go mod download` + `CGO_ENABLED=0 GOOS=linux go build` + `docker build`）。

### シナリオ

| シナリオ | 状態 |
|---|---|
| `cold` | builder を作り直し、Go モジュール/ビルドキャッシュ・KOCACHE・ベースイメージすべて空 |
| `warm` | 全キャッシュがホット、ソース変更なし（no-op ビルド） |
| `change` | 全キャッシュがホット、毎回 `main.go` を書き換えてから再ビルド |

## 結果（秒, n=10）

`trim` は最速・最遅を 1 つずつ除いた 8 回の平均。`ci95±` は平均の 95% 信頼区間の幅。

### cold — 完全なコールドスタート（CI の使い捨てランナー相当）

| 方式 | min | median | max | mean | trim | sd | ci95± |
|---|---:|---:|---:|---:|---:|---:|---:|
| multistage | 41.19 | 42.97 | 49.78 | **43.71** | 43.27 | 2.64 | 1.63 |
| copy | 30.20 | 31.82 | 34.04 | **31.98** | 31.94 | 1.10 | 0.68 |
| ko | 29.26 | 31.28 | 34.89 | **31.44** | 31.28 | 1.60 | 0.99 |

→ **multistage のみ有意に遅い**（43.71 ± 1.63 vs 31〜32 秒台）。
copy と ko は信頼区間が重なっており、**両者に有意差はない**。

multistage の内訳（`FROM golang` の pull は 10 回すべてで 8.5〜8.8 s と極めて安定）:

| ステップ | 秒 |
|---|---:|
| `FROM golang:1.26.5-alpine` の pull | 8.5〜8.8 |
| `WORKDIR /app` | 約 1.5 |
| `go mod download -x` | 約 5.2 |
| `go build` | 19.0〜26.9 |
| `COPY --from=build` / export / load | 約 0.9 |
| （manifest 解決などのオーバーヘッド） | 約 6 |

→ multistage が約 12 秒遅い主因は依然として **ビルダーイメージの pull（約 8.7 s）**。
ただし `golang:1.26.5`（約 340 MB）→ `golang:1.26.5-alpine`（約 70 MB）の変更で
この pull は **33.9 s → 8.7 s** に短縮された。

copy / ko はホストの Go ツールチェーンを使うためこの pull が発生せず、
ランタイムベース `cgr.dev/chainguard/static`（1 レイヤ 630 KB）の取得のみで済む。

### warm — キャッシュ全ヒット・ソース変更なし

| 方式 | min | median | max | mean | trim | sd | ci95± |
|---|---:|---:|---:|---:|---:|---:|---:|
| multistage | 1.26 | 1.30 | 1.35 | **1.31** | 1.31 | 0.03 | 0.02 |
| copy | 1.54 | 1.60 | 1.70 | **1.60** | 1.60 | 0.05 | 0.03 |
| ko | 1.26 | 1.31 | 1.36 | **1.31** | 1.30 | 0.03 | 0.02 |

→ multistage と ko は完全に同値（1.31 s）。copy だけ +0.29 s 遅く、これは統計的には
有意だが、実体は **13.4 MB の `server` バイナリのビルドコンテキスト転送**であり
実用上の意味はない。multistage は全レイヤ `CACHED`、ko はビルドキャッシュヒット。

### change — `main.go` を変更してから再ビルド（開発ループ）

| 方式 | min | median | max | mean | trim | sd | ci95± |
|---|---:|---:|---:|---:|---:|---:|---:|
| multistage | 2.41 | 2.54 | 2.86 | **2.58** | 2.56 | 0.14 | 0.09 |
| copy | 2.27 | 2.32 | 2.36 | **2.32** | 2.33 | 0.03 | 0.02 |
| ko | 2.38 | 2.46 | 2.58 | **2.46** | 2.45 | 0.06 | 0.04 |

→ copy < ko < multistage の順で有意差はあるが、**最大でも 0.26 s 差**。
BuildKit の `cache mount`（`gomodcache` / `gobuildcache`）が効いており、
multistage でもコンテナ内の `go build` は 0.5 s で完了する。実用上は差なしと言ってよい。

## 生成イメージの比較

| 方式 | サイズ | レイヤ数 | ベースイメージ | ENTRYPOINT | USER |
|---|---:|---:|---|---|---|
| multistage | **15,527,551 B (14.81 MiB)** | 2 | `cgr.dev/chainguard/static` | `/bin/server` | `65532` (nonroot) |
| copy | **15,527,551 B (14.81 MiB)** | 2 | `cgr.dev/chainguard/static` | `/bin/server` | `65532` (nonroot) |
| ko | **15,527,551 B (14.81 MiB)** | 3 | `cgr.dev/chainguard/static` | `/ko-app/benchmark-go-docker-build` | `65532` (nonroot) |

- ベースを揃えた結果、**3 方式とも 1 バイトの狂いもなく同一サイズ**になった。
  ビルドフラグ（`-ldflags="-s" -trimpath`）が同じである以上、
  3 方式の違いは「どこでコンパイルし、どう詰めるか」だけであることの決定的な裏付け。
- **USER も 3 方式とも `65532`（nonroot）に揃った**。
  `cgr.dev/chainguard/static` が `USER 65532` を持つため、
  Dockerfile 側で `USER` を書かなくても非 root で起動する。

### レイヤ数の差はどこから来るか（2 vs 3）

| 方式 | ベースのレイヤ数 | ツールが足すレイヤ | 合計 |
|---|---:|---:|---:|
| multistage / copy | 1 | 1（`COPY`） | 2 |
| ko | 1 | 2 | 3 |

`cgr.dev/chainguard/static` は apko でビルドされており、rootfs 全体が **1 レイヤ**。

**ko が足す 2 レイヤ**（`docker save` して実際の tar を展開して確認）:

| レイヤ | 内容 | サイズ（非圧縮） |
|---|---|---:|
| `[1]` | `/var/run/ko`（kodata レイヤ。`kodata/` ディレクトリが無くても必ず生成される） | 2,560 B |
| `[2]` | `/ko-app/benchmark-go-docker-build`（Go バイナリ） | 13,437,440 B |

ko は「静的アセット（kodata）とバイナリを別レイヤに分ける」設計なので常に 2 レイヤ固定。
Dockerfile 側は `COPY` 1 命令 = 1 レイヤなので 1 枚。
残る差はこの kodata レイヤ 2.5 KB のみで、実用上の意味はない。

## Dockerfile 変更前との比較

変更前は builder が `golang:1.26.5`、ランタイムベースが
`gcr.io/distroless/static-debian13` だった（前回計測 n=3）。

| 指標 | 変更前 | 変更後 | 差 |
|---|---:|---:|---|
| cold: multistage | 70.12 s | **43.71 s** | **−26.4 s (−38%)** |
| cold: copy | 35.90 s | 31.98 s | −3.9 s |
| cold: ko | 38.04 s | 31.44 s | −6.6 s（※ ko は Dockerfile 非依存、下記参照） |
| multistage/copy のサイズ | 15,646,986 B | **15,527,551 B** | −119,435 B |
| multistage/copy のレイヤ数 | 14 | **2** | −12 |
| multistage/copy の USER | `0` (root) | **`65532` (nonroot)** | 非 root 化 |

- **multistage の cold が 38% 短縮**。alpine ビルダーへの変更がそのまま効いている。
- ko は Dockerfile を一切使わないため、本来この変更の影響を受けない。
  前回の ko cold（n=3, sd 大）が上振れしていたための見かけ上の差で、
  今回 n=10 の 31.44 s（ci95 ±0.99）が実力値と考えられる。
- **セキュリティ面の改善が大きい**: Dockerfile 側 2 方式が root → nonroot になり、
  `USER` を明示せずとも ko と同じ姿勢になった。

## まとめ

| 観点 | multistage | copy | ko |
|---|---|---|---|
| 完全コールド | △ 43.7 s（+12 s / builder image pull 8.7 s） | ◎ 32.0 s | ◎ 31.4 s |
| ウォーム | ◎ 1.31 s | ○ 1.60 s | ◎ 1.31 s |
| 差分ビルド | ○ 2.58 s | ◎ 2.32 s | ○ 2.46 s |
| イメージサイズ | 14.81 MiB | 14.81 MiB | 14.81 MiB |
| レイヤ数 | 2 | 2 | 3 |
| 非 root | ◎（ベース由来） | ◎（ベース由来） | ◎ |
| ホストに Go ツールチェーン必要 | 不要 | 必要 | 必要 |
| 再現性（ビルド環境の固定） | ◎ Dockerfile で完結 | △ ホスト依存 | △ ホスト依存 |

**結論（このローカル環境において）**

1. **成果物は 3 方式とも実質同一**（バイト単位で同一サイズ、同一ベース、同一 USER、
   差は ko の kodata レイヤ 2.5 KB のみ）。方式の選択は成果物の質では決まらない。
2. **キャッシュが温まっていれば速度差もない**（1.31〜2.58 秒、最大差 0.29 s）。
   日常の開発ループで方式を選ぶ理由は速度ではない。
3. 差が出るのは **完全コールドのみで、約 12 秒**（有意差あり）。原因は
   `golang:1.26.5-alpine` の pull（10 回すべてで 8.5〜8.8 s）というただ 1 点で、
   レジストリミラーやレイヤキャッシュで解消できる範囲。
   alpine 化前は 27 秒差だったので、この変更で差の 2/3 が消えた。
4. **copy と ko は cold で統計的に区別できない**（信頼区間が重なる）。
   両者はどちらも「ホストでコンパイルして薄いベースに載せる」同じ戦略であり、
   実装が Dockerfile か ko かの違いしかないため、この結果は妥当。
5. 残る判断軸は速度ではなく **「ホストに Go ツールチェーンを要求するか」**。
   multistage は Dockerfile だけで完結して再現性が高い。
   copy / ko はホストの Go バージョンが成果物に直結するため、
   CI とローカルでバージョンを揃える仕組みが別途必要。

## 計測ノイズ / この計測の限界

- **ブロック間の再現性は高い**。n=10 は「5 回のブロック」を約 2 時間の間隔を空けて
  2 回実施したもの。両ブロックの平均は以下のとおりよく一致しており、
  日をまたがない範囲では安定して再現できる。

  | シナリオ | 方式 | ブロック1 平均 | ブロック2 平均 | 差 |
  |---|---|---:|---:|---:|
  | cold | multistage | 43.16 | 44.26 | +2.5% |
  | cold | copy | 32.36 | 31.60 | −2.3% |
  | cold | ko | 31.49 | 31.39 | −0.3% |
  | warm | multistage | 1.30 | 1.31 | +0.8% |
  | warm | copy | 1.63 | 1.58 | −3.1% |
  | warm | ko | 1.30 | 1.31 | +0.8% |
  | change | multistage | 2.60 | 2.55 | −1.9% |
  | change | copy | 2.32 | 2.32 | 0.0% |
  | change | ko | 2.45 | 2.47 | +0.8% |

- **一方、連続実行中のセッション内ドリフトは ±12〜22% に達する**。
  約 30 分連続でビルドし続けた中盤に同一条件を再測定したところ、
  multistage 48.24 s / copy 36.97 s / ko 38.34 s と全方式が一様に悪化した。
  マシンを冷ましてから再度 cold を測ると
  multistage 42.86 s / copy 32.44 s / ko 31.37 s と初回ブロックに 1% 以内で復帰したため、
  これは熱ドリフトであり方式間の差ではない。
  **各ブロックは冷えた状態から開始し、シナリオ順（cold → warm → change）を固定して
  全方式が同じ熱条件を通るようにしている。**
- 「ビルドキャッシュだけ空でベースイメージは手元にある」条件は計測できなかった。
  `docker buildx prune --all` はベースイメージも content store から追い出すため
  （`resolve` + `extracting` が再発生することを確認済み）、
  この条件は builder のプルーンでは再現できない。
  代わりに cold のステップ内訳（上記）でベースイメージ pull のコストを分離している。
- **CI（GitHub Actions）の結果とは傾向が異なる**（[`report.md`](report.md) 参照。
  なお `report.md` は Dockerfile 変更前の計測）。
  CI では毎回使い捨てランナーで BuildKit の `cache mount` が失われるため、
  multistage がフルコンパイルを強いられて大きく不利になる。
  ローカルでは builder が永続するのでこの差が消える。
- ホストが Apple Silicon で `linux/arm64` を生成しているため、
  QEMU エミュレーションのコストは含まれていない。
  `linux/amd64` を生成する場合、multistage は VM 内エミュレーションで大幅に遅くなる一方、
  copy / ko はホストのクロスコンパイルなのでほぼ変化しない（この差は本計測に含まれない）。
- `cold` シナリオはモジュールダウンロードとイメージ pull を含むためネットワークの影響を受ける。
- CI で使っている SBOM / provenance 生成（`sbom: true`, `provenance: true`）は
  ローカルの `--load` では使えないため無効。
