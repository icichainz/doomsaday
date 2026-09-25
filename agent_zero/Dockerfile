# Build stage.
FROM golang:1.25-alpine AS build

WORKDIR /src
ENV CGO_ENABLED=0

# Dependencies first, so the layer is cached.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
ARG VERSION=0.1.0
RUN go build -trimpath \
      -ldflags "-s -w -X agent_zero/internal/version.Version=${VERSION}" \
      -o /out/agent_zero ./cmd/agent_zero

# Runtime stage.
#
# The image carries the docker CLI because compose stacks are driven with
# `docker compose`. It does not carry a shell script entrypoint: the binary is
# PID 1 and handles SIGTERM itself.
FROM alpine:3.21

RUN apk add --no-cache ca-certificates docker-cli docker-cli-compose tzdata \
    && addgroup -S agentzero \
    && adduser -S -G agentzero -H -s /sbin/nologin agentzero \
    && mkdir -p /var/lib/agent_zero /opt/stacks \
    && chown agentzero:agentzero /var/lib/agent_zero

COPY --from=build /out/agent_zero /usr/local/bin/agent_zero

# The agent needs the Docker socket, which is root equivalent. Mount it
# read-write and add this container's user to the host's docker group:
#
#   docker run -d --name agent_zero \
#     -p 8443:8443 \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -v agent_zero_data:/var/lib/agent_zero \
#     -v /opt/stacks:/opt/stacks \
#     --group-add "$(getent group docker | cut -d: -f3)" \
#     agent_zero:latest
USER agentzero

VOLUME ["/var/lib/agent_zero"]
EXPOSE 8443

ENV AGENT_ZERO_LISTEN=":8443" \
    AGENT_ZERO_DATA_DIR="/var/lib/agent_zero" \
    AGENT_ZERO_STACKS_DIR="/opt/stacks"

ENTRYPOINT ["/usr/local/bin/agent_zero"]
