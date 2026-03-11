# ------------------------------
# Verdaccio v6 multi-stage Dockerfile (with AWS S3 / Cloudflare R2 plugin)
# - Builds Verdaccio tarball in builder stage
# - Installs verdaccio + aws-s3-storage plugin
# - Compatible with Railway (no VOLUME instruction)
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

# Enable Corepack and activate Yarn 4 (required by Verdaccio repo)
RUN corepack enable && corepack prepare yarn@4.9.2 --activate

WORKDIR /opt/verdaccio-build
COPY . .

# Build Verdaccio and create tarball
RUN yarn config set npmRegistryServer $VERDACCIO_BUILD_REGISTRY && \
    yarn config set enableProgressBars true && \
    yarn config set enableScripts false && \
    yarn install --immutable && \
    yarn build && \
    yarn pack --out verdaccio.tgz && \
    mkdir -p /opt/tarball && \
    mv /opt/verdaccio-build/verdaccio.tgz /opt/tarball/

# clean builder workspace
RUN rm -rf /opt/verdaccio-build


# ------------------------------
# Runtime image
# ------------------------------

FROM node:22.22.0-alpine

LABEL maintainer="https://github.com/verdaccio/verdaccio"

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

WORKDIR $VERDACCIO_APPDIR

RUN apk --no-cache add \
    openssl \
    dumb-init

# create directories
RUN mkdir -p \
    /verdaccio/storage \
    /verdaccio/plugins \
    /verdaccio/conf

# copy verdaccio build
COPY --from=builder /opt/tarball/verdaccio.tgz $VERDACCIO_APPDIR/verdaccio.tgz

USER root

# install verdaccio + plugin
RUN npm install -g $VERDACCIO_APPDIR/verdaccio.tgz \
    && npm install -g verdaccio-aws-s3-storage@${VERDACCIO_AWS_S3_VERSION} || true \
    && cp /usr/local/lib/node_modules/verdaccio/node_modules/@verdaccio/config/build/conf/docker.yaml /verdaccio/conf/config.yaml \
    && npm cache clean --force \
    && rm -rf .npm/ \
    && rm $VERDACCIO_APPDIR/verdaccio.tgz

# copy custom config if provided
COPY custom-config.yml /verdaccio/conf/config.yaml

# add docker helper scripts
ADD docker-bin $VERDACCIO_APPDIR/docker-bin

RUN chmod +x $VERDACCIO_APPDIR/docker-bin/* \
    && chmod +x /usr/local/lib/node_modules/verdaccio/bin/verdaccio
# create non-root user
RUN adduser \
    -u $VERDACCIO_USER_UID \
    -S \
    -D \
    -h $VERDACCIO_APPDIR \
    -g "$VERDACCIO_USER_NAME user" \
    -s /sbin/nologin \
    $VERDACCIO_USER_NAME

# setup permissions
RUN mkdir -p /verdaccio/storage /verdaccio/conf \
    && touch /verdaccio/conf/htpasswd \
    && chown -R $VERDACCIO_USER_UID:root \
        /verdaccio/storage \
        /verdaccio/conf \
        /usr/local/lib/node_modules/verdaccio \
        /usr/local/lib/node_modules/verdaccio-aws-s3-storage 2>/dev/null || true \
    && chmod -R g=u /verdaccio/storage /verdaccio/conf /etc/passwd \
    && chmod 660 /verdaccio/conf/htpasswd

USER $VERDACCIO_USER_UID

 
EXPOSE $VERDACCIO_PORT

ENTRYPOINT ["dumb-init", "--"]

CMD ["verdaccio", "--config", "/verdaccio/conf/config.yaml", "--listen", "0.0.0.0:4873"]
 