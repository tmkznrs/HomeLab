FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

RUN curl -sSL https://github.com/jgraph/drawio-desktop/releases/download/v29.7.9/drawio-amd64-29.7.9.deb -o /tmp/drawio.deb \
    && apt-get update \
    && apt-get install -y /tmp/drawio.deb \
    && rm /tmp/drawio.deb \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 \
    && install -m 555 /tmp/argocd /usr/local/bin/argocd \
    && rm /tmp/argocd