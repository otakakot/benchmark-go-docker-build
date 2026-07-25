# コールドキャッシュ検証レポート

## 実行一覧

| Run | リンク |
|---|---|
| Run #32 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30160984603 |
| Run #33 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30161095294 |
| Run #34 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30161197063 |
| Run #36 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30161315075 |
| Run #37 | https://github.com/otakakot/benchmark-go-docker-build/actions/runs/30161412171 |

各Runの直前にすべてのキャッシュを削除した状態で実行。

## 結果（ジョブ完了時間, 秒）

| Job | #32 | #33 | #34 | #36 | #37 | トリム平均 |
|---|---|---|---|---|---|---|
| **ko-build** 🥇 | 50 | 45 | 45 | 51 | 49 | **48.0** |
| **copy-build** 🥈 | 47 | 61 | 49 | 51 | 50 | **50.0** |
| **multistage-build** 🥉 | 62 | 54 | 58 | 63 | 60 | **60.0** |
| multistage-build-cache | 76 | 71 | 101 | 89 | 75 | **80.0** |
| cache-dance | 103 | 107 | 131 | 112 | 107 | **108.7** |

※トリム平均: 各5回中、最速・最遅を除いた3回の平均

## 考察

キャッシュなしのコールドスタートでは、**ko-build**（48.0s）と **copy-build**（50.0s）が最速。`type=gha` に依存する multistage-build-cache / cache-dance は cache export のオーバーヘッド（16-27s）が乗るため、コールドスタートではむしろ不利。
