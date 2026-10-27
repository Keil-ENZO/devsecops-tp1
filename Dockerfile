# syntax=docker/dockerfile:1.27@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e

# ---- Étape 1 : préparation des dépendances (image -dev : pip disponible) ----
FROM cgr.dev/chainguard/python:latest-dev@sha256:894aed3297d91283e1fc4c542f5374a4b5f3726134fda7c94eaa539342be1e05 AS builder

WORKDIR /app

# Manifeste copié seul : la couche d'installation reste en cache tant que
# requirements.txt ne change pas, même si le code applicatif évolue.
COPY requirements.txt .

# Cache pip persistant hors couche : seules les dépendances modifiées sont
# retéléchargées, rien n'est embarqué dans l'image.
# Jeton du dépôt privé monté en tmpfs le temps du RUN, jamais en ARG/ENV.
RUN --mount=type=cache,id=pip,target=/home/nonroot/.cache/pip,uid=65532,gid=65532,sharing=locked \
    --mount=type=secret,id=pip_token,required=true,uid=65532,mode=0400 \
    test -s /run/secrets/pip_token \
    && python -m venv /app/venv \
    && /app/venv/bin/pip install -r requirements.txt \
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
