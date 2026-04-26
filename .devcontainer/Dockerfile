FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends wget \
    && wget -q https://github.com/jgraph/drawio-desktop/releases/download/v29.7.9/drawio-amd64-29.7.9.deb -O /tmp/drawio.deb \
    && apt-get install -y /tmp/drawio.deb \
    && rm /tmp/drawio.deb \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*