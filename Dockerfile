# ------------------------------
# Stage 1: Build Verdaccio
# ------------------------------
FROM --platform=${BUILDPLATFORM:-linux/amd64} node:24-alpine AS builder

ENV NODE_ENV=development \
    VERDACCIO_BUILD_REGISTRY=https://registry.npmjs.org

RUN apk add --no-cache git python3 make g++ openssl bash curl

WORKDIR /opt/verdaccio-build

# Copy Verdaccio source
COPY . .

# Enable pnpm
RUN corepack enable && corepack prepare pnpm@10.5.2 --activate

# Install workspace dependencies
RUN pnpm config set registry $VERDACCIO_BUILD_REGISTRY && \
    pnpm install --frozen-lockfile

# Build Verdaccio (builds all workspace plugins including aws-storage)
RUN pnpm run build

# Remove dev deps
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

RUN apk add --no-cache openssl dumb-init bash curl

RUN mkdir -p /verdaccio/conf /verdaccio/plugins
COPY packages/config/src/conf/custom-config.yml /verdaccio/conf/config.yaml

# Copy built Verdaccio
COPY --from=builder /opt/verdaccio-build .

# Create user
RUN adduser -u $VERDACCIO_USER_UID -S -D -h $VERDACCIO_APPDIR -g "$VERDACCIO_USER_NAME user" -s /sbin/nologin $VERDACCIO_USER_NAME && \
    chmod -R +x $VERDACCIO_APPDIR/packages/verdaccio/bin $VERDACCIO_APPDIR/docker-bin && \
    chmod -R g=u /verdaccio/conf /etc/passwd

USER $VERDACCIO_USER_UID

EXPOSE $VERDACCIO_PORT

ENTRYPOINT ["dumb-init", "--", "uid_entrypoint"]

CMD ["sh", "-c", "exec \"$VERDACCIO_APPDIR/packages/verdaccio/bin/verdaccio\" --config /verdaccio/conf/config.yaml --listen \"$VERDACCIO_PROTOCOL://$VERDACCIO_ADDRESS:$VERDACCIO_PORT\""]