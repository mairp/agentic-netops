# syntax=docker/dockerfile:1
# Multi-stage build for ainetops-srv6-controller
FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags='-s -w' -tags ainetops_k8s \
      -o /out/srv6-controller ./cmd/srv6-controller

FROM gcr.io/distroless/static:nonroot AS runtime
WORKDIR /
USER nonroot:nonroot
COPY --from=builder /out/srv6-controller /srv6-controller
ENTRYPOINT ["/srv6-controller"]
