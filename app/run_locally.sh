#!/usr/bin/env bash

# brew install pipx && \
# pipx ensurepath && \
# pipx install poetry && \
poetry env use python3.12 && \
poetry install --no-root && \
poetry run ruff format app.py && \
poetry run streamlit run app.py --server.port=8501 --server.headless=true