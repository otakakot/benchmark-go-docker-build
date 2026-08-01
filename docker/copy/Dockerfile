# syntax=docker/dockerfile:1
# check=error=true

FROM cgr.dev/chainguard/static:latest@sha256:399c8cb4858f05aaa33f43f02a2e75f28d40f016c0f86e5ba6075769e3303791

COPY server /bin/server

ENTRYPOINT ["/bin/server"]
