# Dev container base image, 
# Dependencies are installed at runtime using UV to /opt/venv, not to the image
FROM python:3.12-slim-bookworm

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_CACHE_DIR=/home/vscode/.cache/uv \
    PATH=/opt/venv/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        curl \
        ca-certificates \
        make \
        postgresql-client \
        procps \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.5.11 /uv /usr/local/bin/uv

RUN groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash ${USERNAME} \
    && mkdir -p /opt/venv ${UV_CACHE_DIR} \
    && chown -R ${USER_UID}:${USER_GID} /opt/venv /home/${USERNAME}

USER ${USERNAME}
WORKDIR /workspaces/telco-cewas
