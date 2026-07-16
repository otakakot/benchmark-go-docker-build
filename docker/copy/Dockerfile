# syntax=docker/dockerfile:1
# check=error=true

FROM gcr.io/distroless/static-debian13:latest@sha256:9197324ba51d9cd071af8505989365c006adf9d6d2067eada25aef00abbb5278

COPY server /bin/server

ENTRYPOINT ["/bin/server"]
