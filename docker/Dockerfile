# syntax=docker/dockerfile:1

ARG PYTHON_VERSION=3.12.9
ARG BOOKWORM_DIGEST="sha256:99bb27b18fc0b930cdc372f9e17fe4b0c2a50686504c8ed8aa32397acbad603b"
ARG SLIM_DIGEST="sha256:34656cd90456349040784165b9decccbcee4de66f3ead0a1168ba893455afd1e"
# Retrieved with docker pull/docker inspect --format='{{index .RepoDigests 0}}' python:3.12.7-bookworm

FROM python:${PYTHON_VERSION}-bookworm@${BOOKWORM_DIGEST} AS builder
ARG POETRY_VERSION=1.8

WORKDIR /app

# Prevents Python from writing pyc files.
# ENV PYTHONDONTWRITEBYTECODE=1
# Keeps Python from buffering stdout and stderr to avoid situations where
# the application crashes without emitting any logs due to buffering.
# ENV PYTHONUNBUFFERED=1

ENV POETRY_NO_INTERACTION=1 \
    POETRY_VIRTUALENVS_IN_PROJECT=1 \
    POETRY_VIRTUALENVS_CREATE=1 \
    POETRY_CACHE_DIR=/opt/.cache \
    POETRY_HOME=/opt/poetry \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive

# Download dependencies as a separate step to take advantage of Docker's caching.
# Leverage a cache mount to /root/.cache/pip to speed up subsequent builds.
# Leverage a bind mount to requirements.txt to avoid having to copy them into
# into this layer.
# --mount=type=bind,source=requirements.txt,target=requirements.txt \
# python -m pip install -r requirements.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip install --no-cache-dir --upgrade "poetry==${POETRY_VERSION}"

# Copy dependency files early to utilize Docker layer caching
COPY pyproject.toml /app

# Install development dependencies. We isolate them in their own layer so we will not
# have to redownload them each time we build the project on our machine.
RUN --mount=type=cache,target=/root/.cache/pypoetry \
    poetry install --no-root && \
    rm -rf $POETRY_CACHE_DIR

###########################################################################
FROM python:${PYTHON_VERSION}-slim@${SLIM_DIGEST}

# Metadata labels for documentation
LABEL maintainer="David Aparicio <david.aparicio@free.fr>" \
      description="Streamlit NYC Ridesharing Demo" \
      version="0.1.0"

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONHASHSEED=0 \
    VIRTUAL_ENV=/app/.venv \
    PATH="/app/.venv/bin:$PATH" \
    MPLCONFIGDIR=/tmp/matplotlib \
    DEBIAN_FRONTEND=noninteractive

# Create a non-root user and group for security (Principle of least privilege)
# See https://docs.docker.com/go/dockerfile-user-best-practices/
RUN groupadd --system appuser && \
    useradd --no-log-init --system --gid appuser --no-create-home appuser && \
    mkdir -p /tmp/matplotlib && \
    chown -R appuser:appuser /app /tmp/matplotlib

# Switch to the non-privileged user to run the application.
USER appuser

# Retrieve dependencies/virtual env from the builder
COPY --from=builder ${VIRTUAL_ENV} ${VIRTUAL_ENV}

# Copy the Streamlit source code+config into the container.
COPY .streamlit/ .
COPY app.py .
# COPY --parents .streamlit/ assets/ app/ .
#--parents do the same than the X follow lines, but in the same layer (dockerfile:1.7-labs)

# Expose the default Streamlit port
EXPOSE 8501

# Define a health check to monitor the application's health
# This command checks if the application is responding on the health endpoint
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl --fail http://localhost:8501/healthz || exit 1

# Command to run your Streamlit app
CMD ["streamlit", "run", "app.py"]