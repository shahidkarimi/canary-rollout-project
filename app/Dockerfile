# syntax=docker/dockerfile:1
#
# One image, two runtimes:
#  - EC2/Docker: runs podinfo directly (plain HTTP server on :9898)
#  - Lambda:     the AWS Lambda Web Adapter in /opt/extensions proxies API GW
#                events to the same HTTP server; the adapter is inert outside Lambda.
#
# Reproducibility: podinfo source pinned to an exact commit, all base images
# pinned by digest, binary built with -trimpath, timestamps normalized via
# SOURCE_DATE_EPOCH (set by the pipeline from the podinfo commit date).

ARG PODINFO_VERSION=6.13.0
ARG PODINFO_COMMIT=875ffa9431368708aef7fb968a4cc369a72884ad

FROM public.ecr.aws/awsguru/aws-lambda-adapter:1.0.1@sha256:1e5ab4d9242167500ed8a7bed8a79b448228aaa51cf382fb51fe4bf8a5f9a811 AS lwa

FROM golang:1.26-alpine@sha256:7a3e50096189ad57c9f9f865e7e4aa8585ed1585248513dc5cda498e2f41812c AS build
ARG PODINFO_VERSION
ARG PODINFO_COMMIT
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 --branch ${PODINFO_VERSION} https://github.com/stefanprodan/podinfo.git . \
    && [ "$(git rev-parse HEAD)" = "${PODINFO_COMMIT}" ] || { echo "commit mismatch: $(git rev-parse HEAD)"; exit 1; }
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath \
    -ldflags "-s -w -X github.com/stefanprodan/podinfo/pkg/version.REVISION=${PODINFO_COMMIT}" \
    -a -o /out/podinfo ./cmd/podinfo

# secret-fp extension: logs secret fingerprint+version in Lambda, inert on EC2
COPY secret-extension /ext
RUN cd /ext && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags "-s -w" -o /out/secret-fp .

# Alpine (same family podinfo ships upstream): minimal, non-root, and accepted
# by Lambda's image loader. The distroless static base produced layers Lambda
# rejected with UnsupportedImageLayerDetected, regardless of compression.
FROM alpine:3.23@sha256:4d889c14e7d5a73929ab00be2ef8ff22437e7cbc545931e52554a7b00e123d8b
ARG PODINFO_VERSION
ARG PODINFO_COMMIT
LABEL org.opencontainers.image.title="podinfo" \
      org.opencontainers.image.version="${PODINFO_VERSION}" \
      org.opencontainers.image.revision="${PODINFO_COMMIT}" \
      org.opencontainers.image.source="https://github.com/shahidkarimi/canary-rollout-project"

# ca-certificates: the secret-fp extension calls Secrets Manager over TLS.
RUN apk add --no-cache ca-certificates \
    && addgroup -S app && adduser -S -G app app

COPY --from=lwa /lambda-adapter /opt/extensions/lambda-adapter
COPY --from=build /out/secret-fp /opt/extensions/secret-fp
WORKDIR /home/app
COPY --from=build /out/podinfo ./podinfo
COPY --from=build /src/ui ./ui

# Adapter -> podinfo wiring (ignored outside Lambda)
ENV AWS_LWA_PORT=9898 \
    AWS_LWA_READINESS_CHECK_PATH=/healthz \
    AWS_LWA_INVOKE_MODE=buffered

EXPOSE 9898
USER app
ENTRYPOINT ["/home/app/podinfo"]
