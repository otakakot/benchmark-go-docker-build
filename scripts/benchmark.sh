#!/usr/bin/env bash
# Benchmark container image build: multistage / copy / ko
#
# All caches are isolated under $BENCH_HOME and a dedicated buildx builder,
# so the host's global Go / BuildKit caches are never touched.
#
# Usage:
#   scripts/benchmark.sh [scenario ...]     # cold warm change  (default: all)
#   RUNS=5 scripts/benchmark.sh cold
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BENCH_HOME="${BENCH_HOME:-${TMPDIR:-/tmp}/benchmark-go-docker-build}"
LOG_DIR="$BENCH_HOME/logs"
RESULT_CSV="${RESULT_CSV:-$BENCH_HOME/results.csv}"
BUILDER="${BUILDER:-bench-builder}"
RUNS="${RUNS:-3}"

GOARCH_HOST="$(go env GOARCH)"
PLATFORM="linux/${GOARCH_HOST}"

export GOCACHE="$BENCH_HOME/gocache"
export GOMODCACHE="$BENCH_HOME/gomodcache"
export KOCACHE="$BENCH_HOME/kocache"
export KO_DOCKER_REPO="ko.local/bench"
export DOCKER_BUILDKIT=1

# ko talks to the daemon directly and ignores docker contexts, so resolve the
# active context endpoint into DOCKER_HOST (macOS sockets are not /var/run).
if [ -z "${DOCKER_HOST:-}" ]; then
  DOCKER_HOST="$(docker context inspect --format '{{.Endpoints.docker.Host}}')"
  export DOCKER_HOST
fi

mkdir -p "$LOG_DIR" "$GOCACHE" "$GOMODCACHE" "$KOCACHE"

TAG_MULTISTAGE="bench/multistage:latest"
TAG_COPY="bench/copy:latest"

now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# ---------------------------------------------------------------- setup ----
BACKUP_DIR="$BENCH_HOME/backup"
mkdir -p "$BACKUP_DIR"
cp main.go "$BACKUP_DIR/main.go"
[ -f server ] && cp server "$BACKUP_DIR/server" || true

restore() {
  cp "$BACKUP_DIR/main.go" "$REPO_ROOT/main.go"
  [ -f "$BACKUP_DIR/server" ] && cp "$BACKUP_DIR/server" "$REPO_ROOT/server" || true
  log "restored main.go / server"
}
trap restore EXIT

if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  log "creating buildx builder: $BUILDER"
  docker buildx create --name "$BUILDER" --driver docker-container --bootstrap >/dev/null
fi

if [ ! -f "$RESULT_CSV" ]; then
  echo "scenario,target,run,seconds" >"$RESULT_CSV"
fi

record() { # scenario target run seconds
  echo "$1,$2,$3,$4" >>"$RESULT_CSV"
  log "  -> $1/$2 run=$3 : $4 s"
}

# --------------------------------------------------------------- builds ----
build_multistage() { # everything (module download + compile) happens in BuildKit
  docker buildx build \
    --builder "$BUILDER" \
    --platform "$PLATFORM" \
    --file docker/multistage/Dockerfile \
    --tag "$TAG_MULTISTAGE" \
    --load \
    --progress plain \
    .
}

build_copy() { # compile on host, then COPY the binary into a scratch-ish image
  go mod download
  CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH_HOST" \
    go build -ldflags="-s" -trimpath -o server .
  docker buildx build \
    --builder "$BUILDER" \
    --platform "$PLATFORM" \
    --file docker/copy/Dockerfile \
    --tag "$TAG_COPY" \
    --load \
    --progress plain \
    .
}

build_ko() { # ko compiles on host and assembles the image itself
  ko build --bare --tags latest --platform "$PLATFORM" .
}

run_target() { # scenario target run
  local scenario="$1" target="$2" run="$3"
  local logfile="$LOG_DIR/${scenario}-${target}-${run}.log"
  local start end
  # `server` is an artifact of the copy workflow only; multistage/ko must not
  # pay for it in build-context transfer.
  rm -f "$REPO_ROOT/server"
  start="$(now)"
  if ! "build_${target}" >"$logfile" 2>&1; then
    log "!! FAILED ${scenario}/${target} run=${run} (see $logfile)"
    tail -20 "$logfile" >&2
    return 1
  fi
  end="$(now)"
  record "$scenario" "$target" "$run" \
    "$(python3 -c "print(f'{${end}-${start}:.2f}')")"
}

# --------------------------------------------------------------- caches ----
purge_all_caches() {
  # Go module cache files are read-only; clean via the toolchain first.
  go clean -modcache >/dev/null 2>&1 || true
  chmod -R u+w "$GOMODCACHE" >/dev/null 2>&1 || true
  rm -rf "$GOCACHE" "$GOMODCACHE" "$KOCACHE"
  mkdir -p "$GOCACHE" "$GOMODCACHE" "$KOCACHE"
  if [ "${RESET_BUILDER:-0}" = "1" ]; then
    # `buildx prune --all` keeps already-pulled base images in the builder's
    # content store. Recreating the builder is the only true cold start.
    docker buildx rm "$BUILDER" >/dev/null 2>&1 || true
    docker buildx create --name "$BUILDER" --driver docker-container --bootstrap >/dev/null 2>&1
  else
    docker buildx prune --builder "$BUILDER" --all --force >/dev/null 2>&1 || true
  fi
  docker image rm -f "$TAG_MULTISTAGE" "$TAG_COPY" >/dev/null 2>&1 || true
  for ref in $(docker images --format '{{.Repository}}:{{.Tag}}' 'ko.local/bench' 2>/dev/null); do
    docker image rm -f "$ref" >/dev/null 2>&1 || true
  done
  rm -f "$REPO_ROOT/server"
}

mutate_source() { # force a recompile of the application package only
  local marker="$1"
  sed -e "s|ctx.JSON(http.StatusOK, \"[^\"]*\")|ctx.JSON(http.StatusOK, \"ok-${marker}\")|" \
    "$BACKUP_DIR/main.go" >"$REPO_ROOT/main.go"
}

warmup() {
  log "warmup: populating caches for all three targets"
  build_multistage >"$LOG_DIR/warmup-multistage.log" 2>&1
  build_copy >"$LOG_DIR/warmup-copy.log" 2>&1
  build_ko >"$LOG_DIR/warmup-ko.log" 2>&1
}

# ------------------------------------------------------------- scenarios ----
scenario_cold() {
  log "=== scenario: cold (fresh builder, no Go module/build cache, no base images) ==="
  local RESET_BUILDER=1
  for run in $(seq 1 "$RUNS"); do
    for target in multistage copy ko; do
      log "cold run=$run target=$target : purging caches + recreating builder"
      purge_all_caches
      run_target cold "$target" "$run"
    done
  done
}

scenario_warm() {
  log "=== scenario: warm (all caches hot, source unchanged) ==="
  purge_all_caches
  warmup
  for run in $(seq 1 "$RUNS"); do
    for target in multistage copy ko; do
      run_target warm "$target" "$run"
    done
  done
}

scenario_change() {
  log "=== scenario: change (caches hot, main.go modified before every build) ==="
  purge_all_caches
  warmup
  for run in $(seq 1 "$RUNS"); do
    for target in multistage copy ko; do
      mutate_source "${target}-${run}"
      run_target change "$target" "$run"
    done
  done
  cp "$BACKUP_DIR/main.go" "$REPO_ROOT/main.go"
}

image_sizes() {
  log "=== image sizes ==="
  {
    echo "target,image,bytes"
    for pair in "multistage $TAG_MULTISTAGE" "copy $TAG_COPY" "ko ko.local/bench:latest"; do
      set -- $pair
      size="$(docker image inspect "$2" --format '{{.Size}}' 2>/dev/null || echo 0)"
      echo "$1,$2,$size"
    done
  } >"$BENCH_HOME/sizes.csv"
  cat "$BENCH_HOME/sizes.csv" >&2
}

# ------------------------------------------------------------------ main ----
scenarios=("$@")
[ ${#scenarios[@]} -eq 0 ] && scenarios=(cold warm change)

log "repo=$REPO_ROOT platform=$PLATFORM runs=$RUNS scenarios=${scenarios[*]}"
for s in "${scenarios[@]}"; do
  "scenario_${s//-/_}"
done
image_sizes

log "=== done. results: $RESULT_CSV ==="
column -s, -t "$RESULT_CSV" >&2
