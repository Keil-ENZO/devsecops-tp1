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

### Contrat figé (vérifié le 2026-10-08)

| Point | Valeur retenue |
|---|---|
| Image API | `ghcr.io/keil-enzo/devsecops-tp1-api` (owner en minuscules) |
| Image DB | pas de rebuild, image Chainguard utilisée telle quelle dans la compose |
| Port API | `5000`, bind `0.0.0.0` dans le conteneur |
| UID API | `65532` (`nonroot`, défaut de l'image Chainguard python) |
| UID DB | `70` (`postgres`), l'entrypoint démarre root puis bascule via `setpriv` |
| Venv | `/app/venv` |
| Python runtime | `/usr/bin/python3` → 3.14.8 |
| Commande API | `ENTRYPOINT ["/app/venv/bin/python", "app.py"]`, `WORKDIR /app` |
| Healthcheck API (B) | `["CMD", "/usr/bin/python3", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=3).status == 200 else 1)"]` |
| Healthcheck DB (B) | `["CMD", "pg_isready", "-U", "testuser", "-d", "testdb"]` |

Digests (index multi-arch, à recopier tels quels) :

```
# A : builder
cgr.dev/chainguard/python:latest-dev@sha256:894aed3297d91283e1fc4c542f5374a4b5f3726134fda7c94eaa539342be1e05
# A : runtime
cgr.dev/chainguard/python:latest@sha256:b6248c85ba9b97e1e61b30197f309cc4d21661f889fefa5268f0a7bc530dad46
# B : base de données
cgr.dev/chainguard/postgres:latest@sha256:0c4eaf6cb9bd65337d834f5ebfe79add4312ee2125ab584bf1fbc071abc6bb8f
```

Comparatif qui a motivé le choix (Trivy, HIGH+CRITICAL corrigeables = ce qui fait échouer `--ignore-unfixed --exit-code 1`) :

| Image runtime | Taille | Python | CVE totales | HIGH+CRIT corrigeables |
|---|---|---|---|---|
| `gcr.io/distroless/python3-debian12:nonroot` | 65 Mo | 3.11.2 | 283 | **25** → CI rouge |
| `gcr.io/distroless/python3-debian13:nonroot` | 72 Mo | 3.13.5 | 159 | 0 |
| `cgr.dev/chainguard/python:latest` | 68 Mo | 3.14.8 | **0** | **0** |

Image de test construite (Flask 3.1.3, Werkzeug 3.1.9, psycopg2-binary 2.9.13) :
91 Mo, UID 65532, pas de shell, Trivy 0 CVE, Dive 99,8 %, Hadolint vierge.

Points vérifiés et décisions :
- **Builder et runtime Chainguard de la même famille** : Python dans `/usr/bin` des deux côtés,
  donc les symlinks du venv restent valides une fois copiés.
  Recopier les deux digests **en même temps** pour garder la même version de Python.
- **Le builder `-dev` tourne en non-root** : pas d'écriture dans `/opt`. D'où `/app/venv`.
- **Supprimer pip du venv** en fin de build : `/app/venv/bin/pip uninstall -y pip`.
  Sinon Trivy remonte 4 HIGH dans les libs vendorisées de pip (msgpack, setuptools).
- **Python 3.14** : A doit vérifier que les tests passent avec cette version.
- **Hadolint** : `:latest@sha256:...` ne déclenche pas DL3007 grâce au digest.
- **Healthcheck API indépendant du venv** : il n'utilise que `urllib` (stdlib).
  `/usr/bin/python3` suffit. A peut changer le venv sans casser B.
- **Chainguard Postgres** : `pg_isready` présent, PostgreSQL **18.6**, `PGDATA=/var/lib/postgresql/data`.
  Variables `POSTGRES_USER/PASSWORD/DB` reconnues. Trivy : **0 CVE**.
  Taille 380 Mo, plus lourd que `14-alpine` (285 Mo) : à justifier dans le README.
  L'image contient `sh` et `bash` (entrypoint shell) : ne pas annoncer "sans shell" pour la DB.
- **Passage PG 14 → 18** : volume incompatible, faire `docker compose down -v` avant le premier test.
- Chainguard gratuit = tag `latest` uniquement → épinglage par digest obligatoire.

---

### Personne A
1. **Flake8** : lancer `flake8` avec le `.flake8` fourni, corriger `app.py`/`test_app.py` (noter chaque violation corrigée pour le README).
2. **requirements.txt** : `pip-audit`/`trivy fs` sur l'original → lister CVE (Werkzeug, Flask…), monter Flask 3.x, Werkzeug 3.x récent, pytest 8.x, épingler `psycopg2-binary`. Vérifier que les tests passent.
3. **Dockerfile multi-stage** :
   - stage `builder` : `cgr.dev/chainguard/python:latest-dev@sha256:...`, venv `/app/venv`, `requirements.txt` copié seul avant le code (cache), `pip install --no-cache-dir`, puis `pip uninstall -y pip`
   - stage final : `cgr.dev/chainguard/python:latest@sha256:...`, `COPY --from=builder` venv + `app.py` uniquement, `USER 65532`, `ENTRYPOINT ["/app/venv/bin/python", "app.py"]`
   - attention : digests builder/runtime pris en même temps (même Python 3.14.8)
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
