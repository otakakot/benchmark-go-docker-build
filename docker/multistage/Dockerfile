# syntax=docker/dockerfile:1
# check=error=true

FROM golang:1.26.5-alpine AS build

WORKDIR /app

RUN --mount=type=cache,id=gomodcache,target=/go/pkg/mod/,sharing=locked \
    --mount=type=bind,source=go.sum,target=go.sum \
    --mount=type=bind,source=go.mod,target=go.mod \
    go mod download -x

RUN --mount=type=cache,id=gomodcache,target=/go/pkg/mod/,sharing=locked \
    --mount=type=cache,id=gobuildcache,target=/root/.cache/go-build,sharing=locked \
    --mount=type=bind,target=. \
    CGO_ENABLED=0 go build -ldflags="-s" -trimpath -o /bin/server .

FROM cgr.dev/chainguard/static:latest@sha256:399c8cb4858f05aaa33f43f02a2e75f28d40f016c0f86e5ba6075769e3303791

COPY --from=build /bin/server /bin/

ENTRYPOINT ["/bin/server"]
