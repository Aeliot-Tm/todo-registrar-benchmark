FROM docker:27-cli

RUN apk add --no-cache \
    bash \
    bc \
    git \
    python3
