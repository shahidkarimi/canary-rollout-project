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
ARG PODINFO_COMMIT=1ec15a1a349f4fc69de5af0e500c672c15c1d448

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

FROM gcr.io/distroless/static-debian12:nonroot@sha256:d093aa3e30dbadd3efe1310db061a14da60299baff8450a17fe0ccc514a16639
ARG PODINFO_VERSION
ARG PODINFO_COMMIT
LABEL org.opencontainers.image.title="podinfo" \
      org.opencontainers.image.version="${PODINFO_VERSION}" \
      org.opencontainers.image.revision="${PODINFO_COMMIT}" \
      org.opencontainers.image.source="https://github.com/shahidkarimi/canary-rollout-project"

COPY --from=lwa /lambda-adapter /opt/extensions/lambda-adapter
WORKDIR /home/app
COPY --from=build /out/podinfo ./podinfo
COPY --from=build /src/ui ./ui

# Adapter -> podinfo wiring (ignored outside Lambda)
ENV AWS_LWA_PORT=9898 \
    AWS_LWA_READINESS_CHECK_PATH=/healthz \
    AWS_LWA_INVOKE_MODE=buffered

EXPOSE 9898
USER nonroot:nonroot
ENTRYPOINT ["/home/app/podinfo"]
