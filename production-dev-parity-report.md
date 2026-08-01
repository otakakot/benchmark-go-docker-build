# 本番ビルドとの共通性とローカル開発体験の両立に関する調査レポート

- 調査日: 2026-07-30
- 対象: 本番と Dockerfile / 依存関係 / ビルド条件の共通部分を維持しながら、ローカル開発時だけ hot reload、source sync、debug ツールなどを追加する設計

## 1. 結論

実用上もっともバランスがよいのは、**1つの Dockerfile に共通基盤・開発用・ビルド用・本番用の stage を持たせ、Compose の `build.target` で開発と本番を切り替える方式**である。ただし、stage を1ファイルに記述することは定義の共通化にすぎず、開発と本番が同じビルド経路を通ることを意味しない。

典型的な構成は次のとおり。

```text
base
├── development  Air、Delve、lint、source sync
└── build        本番用バイナリの作成
    └── production  最小 runtime image
```

この方式では、開発コンテナと本番コンテナのイメージも、実際に通る stage も同一ではない。しかし、以下を共通化できる。

- Go / Python / Node などのランタイムバージョン
- lockfile と依存関係の解決
- compiler や OS パッケージなどのビルド環境の基盤
- lockfile、生成コード、アプリケーションソース
- 本番 runtime image へ成果物を渡す経路

Air が `development` stage 内で独自に `go build` を実行する場合、build flags を本番と揃えても、それは「同じビルド経路」ではなく「同等の条件を別々に定義した経路」である。厳密な本番ビルド経路の確認には、`build` から `production` までの target を実際にビルドして起動する必要がある。

一方、**本番イメージそのものを開発に使う方式**は、最終成果物と runtime の parity は最も強いが、distroless や immutable image では shell、compiler、Air、Delve などを持てない。ソースを mount しても実行中のバイナリは更新されないため、hot reload との両立が難しい。

したがって、通常開発は `development` target、本番イメージの起動検証は `production` target を別サービスまたは別 profile で実行する設計が現実的である。

## 2. parity の定義

「本番と同じ」を一つの尺度で扱うと設計を誤りやすい。少なくとも次の3種類に分ける必要がある。

| 種類 | 揃えるもの | 開発時の実現方法 |
|---|---|---|
| ビルド parity | compiler、依存関係、build flags、生成物 | 本番の `build` stage を実際に実行して検証 |
| runtime parity | runtime image、ユーザー、filesystem、entrypoint、healthcheck | `production` target を別途起動して検証 |
| 開発体験 | source sync、hot reload、debug、lint、shell | `development` target にだけツールを追加 |

さらに、共通性の強さを次のように区別する必要がある。

| 水準 | 意味 |
|---|---|
| 同じ Dockerfile | stage の定義が1ファイルに同居しているだけ |
| 共通 base | compiler、OS、依存解決など一部の stage を共有する |
| 同等のビルド条件 | Air と本番 build が同じ flags を別々に指定する |
| 同じビルド経路 | 本番と同じ `build` stage を実際に通る |
| 同じ runtime | `production` stage の成果物をそのまま起動する |

開発 target に Air や Delve を追加しても、それ自体は本番成果物を変えない。重要なのは、**追加ツールを production stage に流出させないこと**、開発用 build command との二重管理を認識すること、そして **`build` → `production` の本番経路を別途継続的に検証すること**である。

## 3. OSS の実例

### 3.1 ShellHub — Go / Air

- Repository: [shellhub-io/shellhub](https://github.com/shellhub-io/shellhub)
- Dockerfile: [server/Dockerfile](https://github.com/shellhub-io/shellhub/blob/master/server/Dockerfile)
- 開発 Compose: [docker-compose.dev.yml](https://github.com/shellhub-io/shellhub/blob/master/docker-compose.dev.yml)
- 開発 entrypoint: [server/entrypoint-dev.sh](https://github.com/shellhub-io/shellhub/blob/master/server/entrypoint-dev.sh)

`server/Dockerfile` は概ね次の関係を持つ。

```text
base → builder → production
base → development
```

`base` で Go の依存関係を取得し、`builder` で本番バイナリを作成する。`production` はそのバイナリだけを runtime image へコピーする。`development` は同じ `base` から派生し、Air、lint、mockery などの開発ツールを追加する。

開発 Compose は `target: development`、ソースディレクトリの bind mount、Air を組み合わせる。テスト Compose では `production` target を使うため、開発と本番の Dockerfile 共通性も確認できる。

**評価**

- Go への適用性: 非常に高い
- 共通基盤: 強い。ただし Air のビルドは本番の `builder` stage と別経路
- runtime parity: 本番 target を別途検証する方式
- hot reload: Air
- 主な注意点: 開発イメージには Docker CLI や lint なども入り、本番イメージとはサイズと攻撃面が異なる

### 3.2 Pairwise Pict Online — Go / Air

- Repository: [tam315/pairwise-pict-online](https://github.com/tam315/pairwise-pict-online)
- Dockerfile: [backend/Dockerfile](https://github.com/tam315/pairwise-pict-online/blob/5dc33f272e16a847c4a357110623b3b582add9ed/backend/Dockerfile)
- Compose: [docker-compose.yml](https://github.com/tam315/pairwise-pict-online/blob/5dc33f272e16a847c4a357110623b3b582add9ed/docker-compose.yml)

開発・コンパイル・本番の stage を連鎖させる構成である。

```text
target_for_development
        ↓
target_for_compilation
        ↓
target_for_production
```

開発 stage に Air と必要な OS ツールを導入し、Compose は `target_for_development`、`./backend` の bind mount、`command: air` を指定する。コンパイル stage が Go バイナリを作り、本番 stage は必要な成果物だけを含む。

**評価**

- Go への適用性: 高い
- 共通基盤: 強い。ただし開発と本番コンパイルは別経路
- hot reload: Air
- 主な注意点: Air の build flags を本番と明示的に揃えないと、debug build と production build が乖離する

### 3.3 Wetterdienst — Python / Compose Watch

- Repository: [earthobservations/wetterdienst](https://github.com/earthobservations/wetterdienst)
- Compose: [compose.yml](https://github.com/earthobservations/wetterdienst/blob/main/compose.yml)
- Dockerfile: [docker/Dockerfile](https://github.com/earthobservations/wetterdienst/blob/main/docker/Dockerfile)

Dockerfile に `build`、`dev`、runtime の stage があり、Compose は開発サービスで `target: dev` を選択する。Python ソースは `sync`、`pyproject.toml` と `uv.lock` は `rebuild` に分けている。

この「ソース変更はコンテナへ同期し、依存変更だけイメージを再構築する」分離は、Go の `*.go`、`go.mod`、`go.sum` にそのまま応用できる。

**評価**

- Compose Watch の参考度: 非常に高い
- parity: 強い
- hot reload: 開発サーバーの reload
- 主な注意点: 開発と本番の stage は完全同一イメージではなく、共通 base と依存関係を揃える方式

### 3.4 MapProxy — Python / profiles

- Repository: [mapproxy/mapproxy](https://github.com/mapproxy/mapproxy)
- Dockerfile: [Dockerfile](https://github.com/mapproxy/mapproxy/blob/master/Dockerfile)
- Compose: [docker-compose.yaml](https://github.com/mapproxy/mapproxy/blob/master/docker-compose.yaml)

`base-libs`、`builder`、`base` を共通化し、`base` から `development` と本番相当の `nginx` stage を派生させている。Compose の profiles で開発サービスと本番相当サービスを切り替える。

開発 stage は `mapproxy-util serve-develop` を実行し、設定ファイルやキャッシュを bind mount する。

**評価**

- profiles と target の参考度: 高い
- parity: 共通依存とアプリケーション層は強い
- 主な注意点: 開発サーバーと本番の nginx / uWSGI では、Web サーバーの挙動や timeout まで同一にはならない

### 3.5 Linked Events — Django / Python

- Repository: [City-of-Helsinki/linkedevents](https://github.com/City-of-Helsinki/linkedevents)
- Dockerfile: [docker/django/Dockerfile](https://github.com/City-of-Helsinki/linkedevents/blob/main/docker/django/Dockerfile)
- Compose: [compose.yaml](https://github.com/City-of-Helsinki/linkedevents/blob/main/compose.yaml)

`appbase` に Python、uv、GDAL、production 依存などを集約し、そこから `development`、`staticbuilder`、`production` を作っている。Compose は開発サービスで `target: development` と `/app` の bind mount を使う。

static asset や OpenAPI schema は専用 stage で生成し、本番 stage が成果物を利用する。開発用依存や Django 開発サーバーは development stage に閉じ込めている。

**評価**

- 大規模サービス構成の参考度: 高い
- parity: 共通 base と production 依存は強い
- 主な注意点: static asset の生成など、本番専用処理は開発時にも別途確認が必要

### 3.6 Stablecoin Studio — NestJS / watch

- Repository: [hashgraph/stablecoin-studio](https://github.com/hashgraph/stablecoin-studio)
- Dockerfile: [apps/backend/Dockerfile](https://github.com/hashgraph/stablecoin-studio/blob/main/apps/backend/Dockerfile)
- Compose: [apps/backend/compose.yaml](https://github.com/hashgraph/stablecoin-studio/blob/main/apps/backend/compose.yaml)

Dockerfile は `development`、`build`、`production` の stage を持つ。開発側は workspace 依存を導入して `nest start --watch` を実行し、build stage は NestJS をコンパイルし、本番 stage は `dist` と production dependencies だけをコピーする。

Node の例だが、開発依存と本番依存を分離しつつ、同じ Node バージョンと lockfile を使う設計が明確である。

**評価**

- multi-stage の参考度: 高い
- hot reload: Nest watch
- 主な注意点: workspace を bind mount する場合、`node_modules` を named volume で保護する必要がある

### 3.7 Ocelot.Social — Node.js / Compose override

- Repository: [Ocelot-Social-Community/Ocelot-Social](https://github.com/Ocelot-Social-Community/Ocelot-Social)
- 本番 Compose: [docker-compose.yml](https://github.com/Ocelot-Social-Community/Ocelot-Social/blob/master/docker-compose.yml)
- 開発 override: [docker-compose.override.yml](https://github.com/Ocelot-Social-Community/Ocelot-Social/blob/master/docker-compose.override.yml)
- backend Dockerfile: [backend/Dockerfile](https://github.com/Ocelot-Social-Community/Ocelot-Social/blob/master/backend/Dockerfile)

通常の Compose は `target: production` を使い、自動適用される override は `target: development` に切り替える。開発時はソースを bind mount し、Nuxt や backend の開発サーバーで hot reload する。

「`docker compose up` は開発、明示的に本番 Compose だけを指定すると production」という運用が README に明記されており、開発と本番の切り替えをチームに定着させやすい。

**評価**

- Compose ファイル分割の参考度: 非常に高い
- parity: 強い
- 主な注意点: 開発 override が暗黙に適用されるため、本番検証時の Compose ファイル指定を誤らない運用が必要

### 3.8 Cloudscale Fleeting Plugin — Go / production rebuild

- Repository: [cloudscale-ch/fleeting-plugin-cloudscale](https://github.com/cloudscale-ch/fleeting-plugin-cloudscale)
- Compose: [compose.yaml](https://github.com/cloudscale-ch/fleeting-plugin-cloudscale/blob/main/compose.yaml)

Compose の `dockerfile_inline` に Go builder と runtime image へのバイナリコピーを定義し、変更時は Compose Watch で再 build する。Air のようなプロセス内 hot reload ではなく、バイナリ再ビルドとコンテナ再作成である。

**評価**

- build pipeline parity: 強い
- hot reload: 弱い
- 用途: 本番 runtime との統合確認

## 4. パターン比較

| パターン | 代表例 | 開発体験 | parity | 向いている用途 |
|---|---|---:|---:|---|
| 同一 Dockerfile の development target | ShellHub、Pairwise、Linked Events | 高 | 共通 base は高、経路は別 | 日常開発と本番定義の共通化 |
| source sync + アプリ watcher | Wetterdienst、Air、Nest watch | 非常に高い | 中〜高 | 高速な inner loop |
| production target の別起動 | ShellHub、MapProxy | 低 | 非常に高い | 本番イメージの smoke test |
| Compose Watch の rebuild | Cloudscale、現在の `multistage` | 中〜低 | 高 | runtime image を含む統合確認 |
| Compose override / profiles | Ocelot、MapProxy | 高 | 高 | 開発・本番の明示的な切り替え |
| ホスト build → runtime image に COPY | 現在の `copy` | 高速 | 成果物は高、環境は弱い | CI の高速化、単純な release build |
| 本番イメージをそのまま開発使用 | distroless 等 | 低 | runtime は最高 | 起動、権限、healthcheck の確認 |

### 本番イメージそのものを使う場合の限界

本番イメージをローカルで起動すること自体は有効である。

- 実際の entrypoint を検証できる
- runtime ユーザーと filesystem 権限を検証できる
- healthcheck、設定、ポート、TLS などを確認できる
- 本番 base image の脆弱性や依存を開発時にも再現できる

しかし、Go の hot reload には向かない。

- distroless には shell や compiler がない
- source を mount しても既存バイナリは変化しない
- Air や Delve を追加すると、それはもはや本番イメージではない
- 本番用の non-root / read-only filesystem と開発用書き込み領域が衝突しやすい

そのため、本番イメージは `prod` profile で別途起動し、通常開発は `development` target を使うのがよい。

## 5. Go への推奨実装

### 5.1 Dockerfile

```dockerfile
# syntax=docker/dockerfile:1

FROM golang:1.26.5 AS base

WORKDIR /app

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod,sharing=locked \
    go mod download

FROM base AS development

# 実際の採用バージョンを固定する
RUN go install github.com/air-verse/air@v1.62.0

COPY . .
CMD ["air", "-c", ".air.toml"]

FROM base AS build

COPY . .
RUN --mount=type=cache,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,target=/root/.cache/go-build,sharing=locked \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/server .

FROM gcr.io/distroless/static-debian13:nonroot AS production

COPY --from=build /out/server /server
USER nonroot:nonroot
ENTRYPOINT ["/server"]
```

重要なのは、`development` と `build` が同じ `base` から派生すること、Air の build command を本番と同じ `CGO_ENABLED`、`GOOS`、`GOARCH`、`-trimpath`、ldflags に揃えることである。ただし、これは条件の同等性を意図した二重定義であり、同一経路を保証しない。本番経路は `production` target のビルドで別途検証する。

Delve や race detector を使う場合は、production parity と混同しないよう `debug` profile または別 target に分ける。

### 5.2 `.air.toml`

Air 側のビルドにも、本番と同等にする条件を明示する。

```toml
[build]
cmd = "CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o ./tmp/server ."
bin = "./tmp/server"
include_ext = ["go"]
exclude_dir = ["tmp", ".git"]
```

開発用のログや debug symbols が必要な場合は、`air` の設定で意図的に差分を作り、その差分を文書化する。

### 5.3 Compose の開発サービス

`develop.watch` を使う場合、ソース変更と依存変更を分離する。

```yaml
services:
  api:
    build:
      context: .
      target: development
    ports:
      - "8080:8080"
    environment:
      GIN_MODE: debug
    volumes:
      - go-mod-cache:/go/pkg/mod
      - go-build-cache:/root/.cache/go-build
    develop:
      watch:
        - action: sync
          path: .
          target: /app
          ignore:
            - .git/
            - tmp/
            - go.mod
            - go.sum
        - action: rebuild
          path: go.mod
        - action: rebuild
          path: go.sum
        - action: rebuild
          path: Dockerfile
        - action: rebuild
          path: .air.toml

volumes:
  go-mod-cache:
  go-build-cache:
```

役割は次のとおり。

- `*.go`: `sync` で `/app` に反映し、Air が再ビルド
- `go.mod` / `go.sum`: `rebuild` で依存関係を再解決
- Dockerfile / `.air.toml`: `rebuild` で開発イメージを更新
- Go module cache / build cache: named volume で保持

`sync` と同じパスを `.:/app` の bind mount でも mount する場合は、反映順序が分かりにくくなるため、どちらか一方にする。

### 5.4 本番相当サービス

本番 image の確認は開発サービスと分ける。

```yaml
  api-prod:
    build:
      context: .
      target: production
    ports:
      - "8081:8080"
    environment:
      GIN_MODE: release
    profiles:
      - prod
```

通常開発では `development` target、本番 smoke test や CI では `production` target を使用する。

## 6. parity を壊しやすいアンチパターン

### 6.1 開発用と本番用の Dockerfile を完全に分ける

開発側だけ依存関係や OS パッケージが更新され、本番側の不足に気づけなくなる。少なくとも base、lockfile、build script は共通化する。

### 6.2 ホストでビルドしたバイナリを本番 image に COPY する

`copy` 方式は高速だが、ホストの Go バージョン、OS、CPU、CGO 設定に依存する。本番 parity を重視する build は Docker 内で実行し、ホスト build は高速化用の選択肢として分離する。

### 6.3 Air、Delve、Go tool を `latest` で導入する

開発環境だけが更新され、再現性が失われる。開発ツールもバージョンを固定する。

### 6.4 ソース変更のたびに production image を rebuild する

最終 runtime image を検証できる一方、Go の inner loop が遅くなる。ソースは `sync` + Air、依存変更や Dockerfile 変更だけ `rebuild` にする。

### 6.5 開発と本番で build flags を変える

`CGO_ENABLED`、`GOOS`、`GOARCH`、build tags、ldflags、生成コードが異なると、本番でのみ失敗する。Air の build command にも本番条件を明示する。

### 6.6 本番の distroless image に開発ツールを追加する

本番 image のサイズ、脆弱性面積、SBOM、non-root 設計を壊す。追加ツールは development stage に閉じ込める。

### 6.7 bind mount と Compose Watch の `sync` を同じパスに重ねる

ファイルの反映元が複数になり、変更が見えない、初期化順序に依存する、依存ディレクトリが隠れるといった問題が起きる。

## 7. 現在の `compose.yaml` への整理案

対象ファイルは、現在 `multistage`、`copy`、`copy-build`、`ko`、`ko-build` を同じ Compose に定義している。

| サービス | 現在の役割 | parity / 開発体験の評価 |
|---|---|---|
| `multistage` | production Dockerfile を `rebuild` | runtime parity は強いが、ソース変更ごとの rebuild は遅い |
| `copy` | ホストの `server` を distroless に COPY | 本番 runtime 確認には有効だが、ホスト toolchain に依存 |
| `copy-build` | 開発 image でバイナリを作り `/app/server` へコピー | bind mount はあるが watcher がなく、hot reload ではない |
| `ko` | `ko.local/ko:latest` を起動 | ko 経路の検証向け |
| `ko-build` | Docker socket 経由で `ko build` | Docker socket の権限と ko 経路の検証向け |

本番 parity と日常開発を目的にするなら、次のように責務を分けるのがよい。

```text
compose.yaml
└── api: development target + Air + source sync

compose.prod.yaml
└── api-prod: production target + distroless

compose.benchmark.yaml
├── multistage
├── copy
├── copy-build
├── ko
└── ko-build
```

ファイルを分けない場合は profiles を使う。

```text
dev       : 通常開発。Air、source sync、debug
prod      : production target、distroless、smoke test
benchmark : multistage / copy / ko の比較
ko        : Docker socket を必要とする ko build
```

具体的には次を推奨する。

1. `docker/multistage/Dockerfile` を `base`、`development`、`build`、`production` の単一 Dockerfile に整理する。
2. 通常開発サービスは `target: development` とし、`copy`、`ko`、`ko-build` は benchmark または ko profile に移す。
3. `*.go` は source sync または bind mount + Air、`go.mod` / `go.sum` は `rebuild` にする。
4. `GIN_MODE=debug` は development profile に限定し、production profile は `release` にする。
5. production image の起動確認は `api-prod` として別途実行する。
6. Docker socket mount は ko profile のみに閉じ込め、通常開発では不要にする。
7. `container_name` はスケールや複数 checkout を制限するため、通常開発サービスでは外し、必要な benchmark サービスだけに残す。

## 8. 調査対象と参照 URL

### 調査日

2026-07-30

### 主な検索キーワード

- `Dockerfile multi-stage development production`
- `"target: development" Dockerfile`
- `"develop:" "watch:" compose.yaml`
- `"action: sync" "action: rebuild" Docker Compose`
- `"air" "go build" Dockerfile`
- `"AS development" "AS production" "go build"`
- `bind mount source sync hot reload Docker Compose`
- `profiles build.target Dockerfile`
- `Go Dockerfile Air hot reload`
- `FastAPI Docker Compose develop watch`
- `NestJS Dockerfile development production`

### 参照した OSS

- [ShellHub](https://github.com/shellhub-io/shellhub)
- [Pairwise Pict Online](https://github.com/tam315/pairwise-pict-online)
- [Wetterdienst](https://github.com/earthobservations/wetterdienst)
- [MapProxy](https://github.com/mapproxy/mapproxy)
- [Linked Events](https://github.com/City-of-Helsinki/linkedevents)
- [Stablecoin Studio](https://github.com/hashgraph/stablecoin-studio)
- [Ocelot.Social](https://github.com/Ocelot-Social-Community/Ocelot-Social)
- [Fleeting Plugin Cloudscale](https://github.com/cloudscale-ch/fleeting-plugin-cloudscale)
- [Docker Compose Develop Specification](https://docs.docker.com/reference/compose-file/develop/)

## 9. 最終提案

このリポジトリで採用するなら、**ShellHub の Dockerfile stage 設計と Wetterdienst の Watch 分離を組み合わせる**のが最も自然である。

- 本番ビルド: `build` → `production`
- ローカル開発: `base` → `development`、Air + source sync
- 本番確認: `production` target を別 profile で起動
- ベンチマーク: `copy`、`multistage`、`ko` を別 Compose または profile に隔離

これにより、日常開発では hot reload の速度を確保しつつ、本番ビルドの定義と共通基盤を同一 Dockerfile 内に維持できる。ただし、開発時の Air と本番の `build` → `production` は別経路であるため、後者を smoke test や CI で実際に通すことを parity の条件とする。
