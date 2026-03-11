# ------------------------------
# Stage 1: Build Verdaccio
# ------------------------------
FROM --platform=${BUILDPLATFORM:-linux/amd64} node:24-alpine AS builder

ENV NODE_ENV=development \
    VERDACCIO_BUILD_REGISTRY=https://registry.npmjs.org

# Install build tools
RUN apk add --no-cache git python3 make g++ openssl bash curl

WORKDIR /opt/verdaccio-build

# Copy source code
COPY . .

# Enable Corepack and pin pnpm
RUN corepack enable && corepack prepare pnpm@10.5.2 --activate

# Configure pnpm registry and install dependencies with retry
RUN pnpm config set registry $VERDACCIO_BUILD_REGISTRY && \
    set -ex; \
    for i in 1 2 3; do \
        pnpm install --frozen-lockfile --network-concurrency 1 --fetch-timeout 600000 && break || sleep 5; \
    done

# Build Verdaccio
RUN pnpm run build

# ------------------------------
# Stage 2: Production Image
# ------------------------------
FROM node:24-alpine
LABEL maintainer="https://github.com/verdaccio/verdaccio"

ENV VERDACCIO_APPDIR=/opt/verdaccio \
    VERDACCIO_USER_NAME=verdaccio \
    VERDACCIO_USER_UID=10001 \
    VERDACCIO_PORT=4873 \
    VERDACCIO_PROTOCOL=http \
    VERDACCIO_ADDRESS=[::]
ENV PATH=$VERDACCIO_APPDIR/docker-bin:$PATH \
    HOME=$VERDACCIO_APPDIR

WORKDIR $VERDACCIO_APPDIR

# Install runtime dependencies
RUN apk add --no-cache openssl dumb-init bash curl

# Create config folders
RUN mkdir -p /verdaccio/conf /verdaccio/plugins

# Copy built files from builder
COPY --from=builder /opt/verdaccio-build .

# Install S3 storage plugin in the final image
RUN npm install verdaccio-aws-s3-storage

# Create Verdaccio user
RUN adduser -u $VERDACCIO_USER_UID -S -D -h $VERDACCIO_APPDIR -g "$VERDACCIO_USER_NAME user" -s /sbin/nologin $VERDACCIO_USER_NAME && \
    chmod -R +x $VERDACCIO_APPDIR/packages/verdaccio/bin $VERDACCIO_APPDIR/docker-bin && \
    chmod -R g=u /verdaccio/conf /etc/passwd

USER $VERDACCIO_USER_UID

# Expose registry port
EXPOSE $VERDACCIO_PORT

# Remove local storage volume since Cloudflare R2 will be used
# VOLUME /verdaccio/storage

# Entrypoint
# Use dumb-init for proper signal handling, then run uid_entrypoint
ENTRYPOINT ["dumb-init", "--", "uid_entrypoint"]

# Run Verdaccio (JSON CMD; env vars expanded by sh; exec ensures signals reach Verdaccio)
CMD ["sh", "-c", "exec \"$VERDACCIO_APPDIR/packages/verdaccio/bin/verdaccio\" --config /verdaccio/conf/config.yaml --listen \"$VERDACCIO_PROTOCOL://$VERDACCIO_ADDRESS:$VERDACCIO_PORT\""]