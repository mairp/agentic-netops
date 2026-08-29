# syntax=docker/dockerfile:1
# Multi-stage build for ainetops-sonic-provider
FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags='-s -w' -tags ainetops_k8s \
      -o /out/sonic-provider ./cmd/sonic-provider

FROM gcr.io/distroless/static:nonroot AS runtime
WORKDIR /
USER nonroot:nonroot
COPY --from=builder /out/sonic-provider /sonic-provider
ENTRYPOINT ["/sonic-provider"]
