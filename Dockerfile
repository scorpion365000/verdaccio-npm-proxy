# ------------------------------
# Stage 1: Build Verdaccio
# ------------------------------
FROM --platform=${BUILDPLATFORM:-linux/amd64} node:24-alpine AS builder

ENV NODE_ENV=development \
    VERDACCIO_BUILD_REGISTRY=https://registry.npmjs.org

# Build dependencies
RUN apk add --no-cache git python3 make g++ openssl bash curl

WORKDIR /opt/verdaccio-build

# Copy Verdaccio source
COPY . .

# Enable pnpm
RUN corepack enable && corepack prepare pnpm@10.5.2 --activate

# Install workspace dependencies
RUN pnpm config set registry $VERDACCIO_BUILD_REGISTRY && \
    pnpm install --frozen-lockfile

# Install AWS S3 / Cloudflare R2 storage plugin
RUN pnpm add -w verdaccio-aws-s3-storage@11.0.0-6-next.10

# Build Verdaccio
RUN pnpm run build

# Remove dev dependencies to shrink image
RUN pnpm prune --prod


# ------------------------------
# Stage 2: Runtime Image
# ------------------------------
FROM node:24-alpine

LABEL maintainer="https://github.com/verdaccio/verdaccio"

ENV VERDACCIO_APPDIR=/opt/verdaccio \
    VERDACCIO_USER_NAME=verdaccio \
    VERDACCIO_USER_UID=10001 \
    VERDACCIO_PORT=4873 \
    VERDACCIO_PROTOCOL=http \
    VERDACCIO_ADDRESS=0.0.0.0

ENV PATH=$VERDACCIO_APPDIR/docker-bin:$PATH \
    HOME=$VERDACCIO_APPDIR

WORKDIR $VERDACCIO_APPDIR

# Runtime dependencies
RUN apk add --no-cache openssl dumb-init bash curl

# Create required folders
RUN mkdir -p /verdaccio/conf \
             /verdaccio/plugins \
             /verdaccio/storage

# Copy built Verdaccio
COPY --from=builder /opt/verdaccio-build .

# Copy your custom config
COPY packages/config/src/conf/custom-config.yml /verdaccio/conf/config.yaml

RUN adduser -u $VERDACCIO_USER_UID -S -D -h $VERDACCIO_APPDIR \
    -g "$VERDACCIO_USER_NAME user" -s /sbin/nologin $VERDACCIO_USER_NAME && \
    mkdir -p /verdaccio/conf /verdaccio/storage && \
    touch /verdaccio/conf/htpasswd && \
    chown -R $VERDACCIO_USER_UID:0 /verdaccio && \
    chmod -R 775 /verdaccio && \
    chmod 660 /verdaccio/conf/htpasswd
    

# Run as non-root
USER $VERDACCIO_USER_UID

# Expose registry port
EXPOSE $VERDACCIO_PORT

# Entrypoint
ENTRYPOINT ["dumb-init", "--"]

# Start Verdaccio
CMD ["sh", "-c", "exec \"$VERDACCIO_APPDIR/packages/verdaccio/bin/verdaccio\" --config /verdaccio/conf/config.yaml --listen \"$VERDACCIO_PROTOCOL://$VERDACCIO_ADDRESS:$VERDACCIO_PORT\""]