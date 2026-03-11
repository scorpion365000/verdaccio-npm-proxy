# ------------------------------
# Multi-stage Dockerfile for Verdaccio
# - Install plugin in builder stage with pnpm (resolves workspace:* URLs)
# - Prune dev deps before copying to final image (smaller image)
# ------------------------------

# ------------------------------
# Stage 1: Build Verdaccio
# ------------------------------
FROM --platform=${BUILDPLATFORM:-linux/amd64} node:24-alpine AS builder

# Build-time environment
ENV NODE_ENV=development \
    VERDACCIO_BUILD_REGISTRY=https://registry.npmjs.org

# Install build tools required for native builds / tooling
RUN apk add --no-cache git python3 make g++ openssl bash curl

WORKDIR /opt/verdaccio-build

# Copy source code and the plugin tarball into the builder.
# (This ensures pnpm can resolve workspace: dependencies referenced by the plugin)
RUN curl -L https://registry.npmjs.org/verdaccio-aws-s3-storage/-/verdaccio-aws-s3-storage-11.0.0-6-next.10.tgz \
  -o verdaccio-aws-s3-storage.tgz

COPY . .
 

# Enable Corepack and pin pnpm
RUN corepack enable && corepack prepare pnpm@10.5.2 --activate

# Configure pnpm registry and install workspace deps (with simple retry)
RUN pnpm config set registry $VERDACCIO_BUILD_REGISTRY && \
    set -ex; \
    for i in 1 2 3; do \
      pnpm install --frozen-lockfile --network-concurrency 1 --fetch-timeout 600000 && break || sleep 5; \
    done

# Install the S3 plugin into the builder's node_modules.
# --no-lockfile avoids modifying the lockfile during this add if you prefer that.
# Remove --no-lockfile if you want the lockfile updated.
RUN pnpm add ./verdaccio-aws-s3-storage-11.0.0-6-next.10.tgz --prod --reporter=silent --no-lockfile

# Build Verdaccio (uses installed deps + plugin if the build expects it)
RUN pnpm run build

# Prune dev dependencies to reduce what we copy into the runtime image
RUN pnpm prune --prod

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

# Create config folders (mounted or filled at runtime)
RUN mkdir -p /verdaccio/conf /verdaccio/plugins

# Copy built files (including pruned node_modules and built assets) from builder
COPY --from=builder /opt/verdaccio-build .

# (Do NOT re-install plugin in the final image; it's already present in node_modules)
# If you previously copied a local .tgz into the final stage, remove those lines.

# Create Verdaccio user and fix permissions
RUN adduser -u $VERDACCIO_USER_UID -S -D -h $VERDACCIO_APPDIR -g "$VERDACCIO_USER_NAME user" -s /sbin/nologin $VERDACCIO_USER_NAME && \
    chmod -R +x $VERDACCIO_APPDIR/packages/verdaccio/bin $VERDACCIO_APPDIR/docker-bin && \
    chmod -R g=u /verdaccio/conf /etc/passwd

# Switch to non-root user
USER $VERDACCIO_USER_UID

# Expose registry port
EXPOSE $VERDACCIO_PORT

# Remove local storage volume since Cloudflare R2 will be used
# VOLUME /verdaccio/storage

# Entrypoint: use dumb-init for proper signal handling, then run uid_entrypoint
ENTRYPOINT ["dumb-init", "--", "uid_entrypoint"]

# Run Verdaccio (env vars expanded by sh; exec ensures signals reach Verdaccio)
CMD ["sh", "-c", "exec \"$VERDACCIO_APPDIR/packages/verdaccio/bin/verdaccio\" --config /verdaccio/conf/config.yaml --listen \"$VERDACCIO_PROTOCOL://$VERDACCIO_ADDRESS:$VERDACCIO_PORT\""]