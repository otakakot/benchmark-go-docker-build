# コールドキャッシュ検証レポート

## 実行一覧

| Run | リンク |
|---|---|
| Run #32 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30160984603 |
| Run #33 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30161095294 |
| Run #34 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30161197063 |
| Run #36 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30161315075 |
| Run #37 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30161412171 |
| Run #38 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30162657669 |
| Run #39 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30162701638 |
| Run #40 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30162740806 |
| Run #41 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30162788874 |
| Run #42 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30162837443 |
| Run #43 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30163292526 |
| Run #44 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30163400268 |
| Run #45 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30163516625 |
| Run #46 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30163598463 |
| Run #47 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30163717180 |

各Runの直前にすべてのキャッシュを削除した状態で実行。

## 結果（ジョブ完了時間, 秒）

### コールドキャッシュ

| Job | #32 | #33 | #34 | #36 | #37 | トリム平均 |
|---|---|---|---|---|---|---|
| ko-build | 50 | 45 | 45 | 51 | 49 | 48.0 |
| copy-build | 47 | 61 | 49 | 51 | 50 | 50.0 |
| multistage-build | 62 | 54 | 58 | 63 | 60 | 60.0 |
| multistage-build-cache | 76 | 71 | 101 | 89 | 75 | 80.0 |
| cache-dance | 103 | 107 | 131 | 112 | 107 | 108.7 |

### ウォームキャッシュ

各Runの直前に `ko build` を1回実行してキャッシュを温めた状態で実行。

| Job | #38 | #39 | #40 | #41 | #42 | トリム平均 |
|---|---|---|---|---|---|---|
| ko-build | 14 | 15 | 20 | 15 | 15 | 15.0 |
| copy-build | 39 | 33 | 31 | 36 | 41 | 36.0 |
| multistage-build | 58 | 56 | 57 | 68 | 62 | 59.0 |
| multistage-build-cache | 26 | 15 | 34 | 20 | 29 | 25.0 |
| cache-dance | 65 | 32 | 45 | 45 | 35 | 41.7 |

### PRブランチ（ghaキャッシュ未達）

各Runは別ブランチ（api-1〜api-5）のPRとして実行。actions/cache（ko-build, copy-build）はリポジトリ全体で共有されるが、gha cache（multistage-build-cache, cache-dance）はブランチスコープのためキャッシュミス。

| Job | #43 | #44 | #45 | #46 | #47 | トリム平均 |
|---|---|---|---|---|---|---|
| ko-build | 19 | 13 | 24 | 13 | 13 | 15.0 |
| copy-build | 37 | 43 | 23 | 29 | 22 | 29.7 |
| multistage-build | 61 | 55 | 67 | 73 | 66 | 64.7 |
| multistage-build-cache | 56 | 63 | 66 | 67 | 66 | 65.0 |
| cache-dance | 68 | 64 | 51 | 49 | 85 | 61.0 |

※トリム平均: 各5回中、最速・最遅を除いた3回の平均
