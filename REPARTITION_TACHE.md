# Plan TP DevSecOps — durcissement Flask/PostgreSQL + CI/CD GHCR (binôme)

## Contexte
Repo actuel : `app.py` (Flask, routes /health /hello /dbtest), `test_app.py` (pytest, test `integration` sur /dbtest), `Dockerfile` mono-stage `python:3.10-slim` root, `docker-compose.yml` avec `postgres:14-alpine` + healthcheck `CMD-SHELL`, `requirements.txt` vieux (Flask 2.3.2, Werkzeug 2.3.3, pytest 7.4.0, psycopg2-binary non épinglé), `.flake8` fourni (max 88, ignore E203,W503,E302,E305,W293,W292,W391). Rien d'autre : pas de .dockerignore, .hadolint.yaml, workflow, README.

## Répartition
**Personne A — « Image & sécurité de l'image »** (tout ce qui touche à l'image API)
**Personne B — « Orchestration & pipeline »** (compose, CI/CD, GHCR)
README : chacun rédige ses sections, B assemble.

Point de contrat entre A et B (à fixer en 10 min au début) :
- nom de l'image (`ghcr.io/<owner>/devsecops-tp1-api`), port 5000, UID non-root (65532 distroless `nonroot`)
- chemin du venv dans l'image (`/app/.venv` ou `/opt/venv`) → nécessaire pour le healthcheck de B
- digest Chainguard Postgres (B), digest image Python (A)

---

### Personne A
1. **Flake8** : lancer `flake8` avec le `.flake8` fourni, corriger `app.py`/`test_app.py` (noter chaque violation corrigée pour le README).
2. **requirements.txt** : `pip-audit`/`trivy fs` sur l'original → lister CVE (Werkzeug, Flask…), monter Flask 3.x, Werkzeug 3.x récent, pytest 8.x, épingler `psycopg2-binary`. Vérifier que les tests passent.
3. **Dockerfile multi-stage** :
   - stage `builder` : image Python (même version mineure que le runtime, épinglée par digest), `python -m venv`, `pip install --no-cache-dir -r requirements.txt` (manifeste copié seul avant le code → cache)
   - stage final : `gcr.io/distroless/python3-debian12:nonroot@sha256:...` (ou `cgr.dev/chainguard/python@sha256:...`), `COPY --from=builder` venv + `app.py` uniquement, `USER 65532` (ou `nonroot`), `ENTRYPOINT`/`CMD` en JSON, `PYTHONPATH` vers site-packages du venv
   - attention : versions Python builder/runtime identiques (distroless debian12 = 3.11)
4. **.dockerignore** : `.git`, `.github`, `__pycache__`, `*.pyc`, `.pytest_cache`, `test_*.py`, `tests/`, `.env*`, `venv/.venv`, `*.log`, `*.tar*`, `*.zip`, `README.md`, `docker-compose*.yml`, `.hadolint.yaml`, `.flake8`, `Dockerfile`.
5. **.hadolint.yaml** : `failure-threshold: warning`, `trustedRegistries: [docker.io, gcr.io, cgr.dev, ghcr.io]`, `override.error: [DL3002, DL3006, DL3007, DL4006]` (+ vérifier DL3025, DL3042, DL3020, DL3022, SC2086, DL3003 non ignorés).
6. **Mesures locales** : `hadolint`, `dive --ci --lowestEfficiency=0.8`, `trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1`, taille, `docker run --entrypoint sh` qui doit échouer. Mesures « avant » sur l'image d'origine aussi (pour le tableau).
7. README : sections 2 (tableau avant/après), 3 (choix images + digests), 5 (flake8 + CVE deps), preuves Flake8/Hadolint/Dive/Trivy.

### Personne B
1. **docker-compose.yml** :
   - `db` : `cgr.dev/chainguard/postgres@sha256:...`, healthcheck `["CMD", "pg_isready", "-U", "testuser", "-d", "testdb"]` (vérifier que le binaire est bien présent dans l'image), volume nommé
   - `api` : build local + `image:` taggable, healthcheck `["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:5000/health').status==200 else 1)"]` (chemin python selon contrat avec A), `depends_on: db: condition: service_healthy`
   - réseaux : `backend` `internal: true` (api↔db), `frontend` pour exposer l'API ; ne plus publier 5432
   - durcissement : `read_only: true`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `tmpfs` /tmp, `user`, limites mem/pids, `restart`
   - secrets via `.env` non commité ou variables, pas en dur si possible
2. **Workflow `.github/workflows/ci.yaml`** (push + PR sur main, tags `v*.*.*`) :
   - `permissions: {}` au niveau global (ou `contents: read`), `packages: write` uniquement sur le job release
   - jobs : `lint-python` (flake8) ‖ `lint-docker` (hadolint-action + config) → `build` (buildx, image en artefact `docker save`) → `dive` & `trivy` (image + `scan-type: fs` sur requirements, `exit-code: 1`, `ignore-unfixed`, HIGH,CRITICAL) → `integration` (compose up `--wait --wait-timeout 120`, `curl /health` `/dbtest`, `pytest`, `docker compose down -v` en `if: always()`) → `release` (`needs:` tout, `if:` push sur tag/main)
   - toutes les actions épinglées par SHA complet (+ commentaire version) : checkout, setup-python, setup-buildx, login-action, metadata-action, build-push-action, hadolint-action, trivy-action, upload/download-artifact
   - SemVer via `docker/metadata-action` : `type=semver,pattern={{version}}`, `{{major}}.{{minor}}`, `{{major}}`, `type=sha`, `latest` sur tag
3. **Release** : créer tag `v1.0.0`, vérifier publication, rendre le package public, lier au repo.
4. README : sections 1 (liens GHCR + `docker pull ...:1.0.0`), 4 (healthchecks sans shell), 6 (CI/CD), preuves compose healthy / pytest / GHCR.

---

## Ordre / jalons
1. (ensemble, 15 min) contrat + création branches `feat/image` (A) et `feat/ci-compose` (B).
2. A : flake8 + requirements + Dockerfile en premier (B en dépend pour tester compose) ; B en parallèle : compose + squelette workflow avec jobs lint.
3. Merge A → B branche le build/dive/trivy sur le vrai Dockerfile, puis integration.
4. Tout vert sur PR → merge main → tag `v1.0.0` → release GHCR.
5. README final + captures de sorties (relecture croisée : A relit le workflow, B relit le Dockerfile).

## Pièges à anticiper
- Distroless n'a pas de shell → healthcheck uniquement `CMD` exec avec python ; `pg_isready` doit exister dans l'image Chainguard (sinon variante `-dev` interdite → vérifier tôt).
- Image Chainguard postgres : variables d'env et chemin data (`/var/lib/postgresql/data`) parfois différents → tester tôt.
- `app.run` dev server : envisager gunicorn (attention au poids/Dive) ou garder Flask si OK.
- Trivy peut remonter des CVE OS distroless non corrigeables → `ignore-unfixed` est conforme à l'énoncé.
- Le test `test_dbtest` doit tourner contre la compose (pytest depuis le runner avec `DB_HOST=localhost` ou via `curl`), sinon il échoue en job unitaire.
- Le nom GHCR doit être en minuscules.

## Vérification finale
`flake8` vierge, `hadolint Dockerfile` vierge, `dive --ci` ≥ 80 %, `trivy` exit 0, `docker compose up --wait` → 2 services healthy, `curl /health` & `/dbtest` OK, `pytest` vert, pipeline GitHub tout vert, `docker pull ghcr.io/<owner>/devsecops-tp1-api:1.0.0` fonctionne.
