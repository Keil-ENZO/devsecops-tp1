# syntax=docker/dockerfile:1

# ---- Étape 1 : préparation des dépendances (image -dev : pip disponible) ----
FROM cgr.dev/chainguard/python:latest-dev@sha256:894aed3297d91283e1fc4c542f5374a4b5f3726134fda7c94eaa539342be1e05 AS builder

WORKDIR /app

# Manifeste copié seul : la couche d'installation reste en cache tant que
# requirements.txt ne change pas, même si le code applicatif évolue.
COPY requirements.txt .

RUN python -m venv /app/venv \
    && /app/venv/bin/pip install --no-cache-dir -r requirements.txt \
    && /app/venv/bin/pip uninstall -y pip

# ---- Étape 2 : exécution (sans shell, sans gestionnaire de paquets) ----
FROM cgr.dev/chainguard/python:latest@sha256:b6248c85ba9b97e1e61b30197f309cc4d21661f889fefa5268f0a7bc530dad46

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY --from=builder /app/venv /app/venv
COPY app.py .

EXPOSE 5000

USER 65532

ENTRYPOINT ["/app/venv/bin/python", "app.py"]
