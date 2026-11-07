# syntax=docker/dockerfile:1
# Build frontend on the native platform to avoid QEMU-related issues with nodejs ecosystem
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.27-alpine3.24 AS frontend-build
RUN apk --no-cache add build-base git nodejs pnpm
WORKDIR /src
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN --mount=type=cache,target=/root/.local/share/pnpm/store pnpm install --frozen-lockfile
COPY --exclude=.git/ . .
RUN make frontend

# Cross-compile backend on the native platform to avoid slow QEMU emulation
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.27-alpine3.24 AS build-env

ARG GITEA_VERSION
ARG TAGS=""
ENV TAGS="bindata timetzdata $TAGS"
ARG CGO_EXTRA_CFLAGS

# Build deps
RUN apk --no-cache add \
    build-base \
    git

WORKDIR ${GOPATH}/src/gitea.dev
COPY go.mod go.sum ./
RUN go mod download
# Use COPY instead of bind mount as read-only one breaks makefile state tracking and read-write one needs binary to be moved as it's discarded.
# ".git" directory is mounted separately later only for version data extraction.
COPY --exclude=.git/ . .
COPY --from=frontend-build /src/public/assets public/assets
RUN --mount=type=cache,target="/root/.cache/go-build" make generate-backend

ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
# Build gitea, .git mount is required for version data
RUN --mount=type=cache,target="/root/.cache/go-build" \
    --mount=type=bind,source=".git/",target=".git/" \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} GOARM=${TARGETVARIANT#v} make gitea

COPY docker/root /tmp/local

# Set permissions for builds that made under windows which strips the executable bit from file
RUN chmod 755 /tmp/local/usr/bin/entrypoint \
              /tmp/local/usr/local/bin/* \
              /tmp/local/etc/s6/gitea/* \
              /tmp/local/etc/s6/openssh/* \
              /tmp/local/etc/s6/.s6-svscan/* \
              /go/src/gitea.dev/gitea

FROM docker.io/library/alpine:3.24 AS gitea

EXPOSE 22 3000

RUN apk --no-cache upgrade && \
    apk --no-cache add \
    bash \
    ca-certificates \
    curl \
    gettext \
    git \
    linux-pam \
    openssh \
    s6 \
    sqlite \
    su-exec \
    tzdata \
    gnupg

RUN addgroup \
    -S -g 1000 \
    git && \
  adduser \
    -S -H -D \
    -h /data/git \
    -s /bin/bash \
    -u 1000 \
    -G git \
    git && \
  echo "git:*" | chpasswd -e

COPY --from=build-env /tmp/local /
COPY --from=build-env /go/src/gitea.dev/gitea /app/gitea/gitea

RUN mkdir -p /app/gitea/custom \
    && ln -s /data/gitea/conf /app/gitea/custom/conf

COPY ./custom/public /app/gitea/custom/public
COPY ./custom/templates /app/gitea/custom/templates
COPY ./scripts/bootstrap.sh /usr/local/bin/gitptit-bootstrap

RUN chmod 0755 /usr/local/bin/gitptit-bootstrap \
    && chown -R 1000:1000 /app/gitea/custom

ENV USER=git \
    GITEA_CUSTOM=/app/gitea/custom \
    TZ=Asia/Ho_Chi_Minh \
    USER_UID=1000 \
    USER_GID=1000 \
    GITEA____APP_NAME=GITPTIT \
    GITEA__server__HTTP_PORT=3000 \
    GITEA__server__LFS_START_SERVER=true \
    GITEA__database__DB_TYPE=postgres \
    GITEA__server__SSH_PORT=2222 \
    GITEA__server__DISABLE_SSH=false \
    GITEA__service__DISABLE_REGISTRATION=false \
    GITEA__service__ALLOW_ONLY_EXTERNAL_REGISTRATION=true \
    GITEA__server__LANDING_PAGE=explore \
    GITEA__actions__ENABLED=true \
    GITEA__oauth2_client__ACCOUNT_LINKING=auto \
    GITEA__oauth2_client__UPDATE_AVATAR=true \
    GITEA__oauth2_client__ENABLE_AUTO_REGISTRATION=true \
    GITEA__oauth2_client__USERNAME=preferred_username \
    GITEA__service__VALID_USERNAME_CHARS=a-zA-Z0-9_-. \
    GITEA__security__INSTALL_LOCK=true

VOLUME ["/data"]

# HINT: HEALTH-CHECK-ENDPOINT: don't use HEALTHCHECK, search this hint keyword for more information
ENTRYPOINT ["/usr/local/bin/gitptit-bootstrap"]
