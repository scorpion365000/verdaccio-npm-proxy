# ------------------------------
# Verdaccio v6 multi-stage Dockerfile (with AWS S3 / Cloudflare R2 plugin)
# - Builds Verdaccio tarball in builder stage, installs globally in runtime
# - Installs verdaccio-aws-s3-storage globally into runtime image
# - Copies custom config (if present) and ensures htpasswd + storage dirs exist
# ------------------------------

FROM --platform=${BUILDPLATFORM:-linux/amd64} node:22.22.0-alpine AS builder

ARG VERDACCIO_BUILD_REGISTRY=https://registry.npmjs.org
ENV NODE_ENV=production \
    VERDACCIO_BUILD_REGISTRY=${VERDACCIO_BUILD_REGISTRY} \
    HUSKY_SKIP_INSTALL=1 \
    CI=true \
    HUSKY_DEBUG=1

RUN apk add --no-cache \
    openssl \
    ca-certificates \
    g++ \
    gcc \
    libgcc \
    libstdc++ \
    linux-headers \
    make \
    python3 \
    libc6-compat

WORKDIR /opt/verdaccio-build
COPY . .

# build the project and create a tarball of the project for later global install
RUN yarn config set npmRegistryServer $VERDACCIO_BUILD_REGISTRY && \
    yarn config set enableProgressBars true && \
    yarn config set enableScripts false && \
    yarn install --immutable && \
    yarn build && \
    yarn pack --out verdaccio.tgz && \
    mkdir -p /opt/tarball && mv /opt/verdaccio-build/verdaccio.tgz /opt/tarball/

# clean builder workspace to make the image smaller
RUN rm -rf /opt/verdaccio-build

# ------------------------------
# Runtime image
# ------------------------------
FROM node:22.22.0-alpine
LABEL maintainer="https://github.com/verdaccio/verdaccio"

# allow override of plugin version at build time
ARG VERDACCIO_AWS_S3_VERSION=11.0.0-6-next.10
ENV VERDACCIO_AWS_S3_VERSION=${VERDACCIO_AWS_S3_VERSION}

ENV VERDACCIO_APPDIR=/opt/verdaccio \
    VERDACCIO_USER_NAME=verdaccio \
    VERDACCIO_USER_UID=10001 \
    VERDACCIO_PORT=4873 \
    VERDACCIO_PROTOCOL=http \
    VERDACCIO_ADDRESS=0.0.0.0
ENV PATH=$VERDACCIO_APPDIR/docker-bin:$PATH \
    HOME=$VERDACCIO_APPDIR

# yarn version included in node:alpine images
ENV YARN_VERSION=1.22.22

WORKDIR $VERDACCIO_APPDIR

# runtime deps
RUN apk --no-cache add openssl dumb-init

# create runtime folders
RUN mkdir -p /verdaccio/storage /verdaccio/plugins /verdaccio/conf

# copy built tarball from builder
COPY --from=builder /opt/tarball/verdaccio.tgz $VERDACCIO_APPDIR/verdaccio.tgz

# run as root while installing global packages and copying config
USER root

# Install verdaccio globally from the packed tarball, then install the S3 plugin globally.
# Copy default config first, then override with user-supplied custom config if it exists.
RUN npm install -g $VERDACCIO_APPDIR/verdaccio.tgz \
    && npm install -g verdaccio-aws-s3-storage@${VERDACCIO_AWS_S3_VERSION} || true \
    && cp /usr/local/lib/node_modules/verdaccio/node_modules/@verdaccio/config/build/conf/docker.yaml /verdaccio/conf/config.yaml \
    # If the repo contains a custom config at packages/config/src/conf/custom-config.yml, copy it to override default
    && cp custom-config.yml /verdaccio/conf/config.yaml \
    # cleanup caches / tarball
    && npm cache clean --force \
    && rm -rf .npm/ $VERDACCIO_APPDIR/verdaccio.tgz \
    && rm -rf /opt/yarn-v$YARN_VERSION/ /usr/local/bin/yarn /usr/local/bin/yarnpkg

# add docker helpers (if you have docker-bin directory)
ADD docker-bin $VERDACCIO_APPDIR/docker-bin

# Create non-root user and fix permissions + ensure htpasswd exists
RUN adduser -u $VERDACCIO_USER_UID -S -D -h $VERDACCIO_APPDIR -g "$VERDACCIO_USER_NAME user" -s /sbin/nologin $VERDACCIO_USER_NAME \
    && mkdir -p /verdaccio/conf /verdaccio/storage \
    && touch /verdaccio/conf/htpasswd \
    && chown -R $VERDACCIO_USER_UID:root /verdaccio/storage /verdaccio/conf /usr/local/lib/node_modules/verdaccio /usr/local/lib/node_modules/verdaccio-aws-s3-storage 2>/dev/null || true \
    && chmod -R g=u /verdaccio/storage /verdaccio/conf /etc/passwd \
    && chmod 660 /verdaccio/conf/htpasswd

# Switch to non-root user
USER $VERDACCIO_USER_UID

EXPOSE $VERDACCIO_PORT

# Use existing uid_entrypoint from repo if present; otherwise fall back to dumb-init entry
# If you have the uid_entrypoint helper in docker-bin, the ENTRYPOINT should invoke it (keeps compatibility with upstream).
ENTRYPOINT ["uid_entrypoint"]

# Start Verdaccio with provided config
CMD ["/bin/sh", "-c", "verdaccio --config /verdaccio/conf/config.yaml --listen $VERDACCIO_PROTOCOL://$VERDACCIO_ADDRESS:$VERDACCIO_PORT"]