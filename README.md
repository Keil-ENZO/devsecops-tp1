# TP DevSecOps : Hardening Flask + PostgreSQL

Rapport d'audit et d'architecture du binôme.
L'état **Avant** est mesuré sur le commit initial `9c6c1d4`.
L'état **Après** est mesuré sur la branche finale.

Outils d'audit :

| Outil | Rôle |
|---|---|
| Flake8 7.4.1 | Qualité du code Python |
| Hadolint | Lint du Dockerfile selon `.hadolint.yaml` |
| pip-audit | CVE du `requirements.txt` |
| Trivy | CVE OS et librairies des images |
| Dive v0.13.1 | Efficience des couches |

Architecture finale :

```
                 réseau frontend
Client ──:5000──> [ api-python ]   Chainguard Python, UID 65532, sans shell
                        │
                 réseau backend  (internal: true, pas d'accès externe)
                        │
                  [ db ]           Chainguard PostgreSQL 18, UID 70, port non publié
```

---

## 1. Liens publics des packages GHCR

| Image | Package |
|---|---|
| API Flask | https://github.com/Keil-ENZO/devsecops-tp1/pkgs/container/devsecops-tp1-api |

Tags publiés par la release `v1.0.0`, tous sur le même digest :

| Tag | Digest |
|---|---|
| `1.0.0` | `sha256:a779745c8ea8ce40fecd6fc019a362bd4d141fadb7e679b429b53ef504a33418` |
| `1.0` | idem |
| `1` | idem |

Image construite pour `linux/amd64`.
Sur Mac Apple Silicon, Docker l'exécute via émulation.

La base de données utilise l'image Chainguard publique, épinglée par digest.
Elle n'est pas reconstruite, donc pas republiée.

Récupération par tag sémantique :

```bash
docker pull ghcr.io/keil-enzo/devsecops-tp1-api:1.0.0
docker pull ghcr.io/keil-enzo/devsecops-tp1-api:1.0
docker pull ghcr.io/keil-enzo/devsecops-tp1-api:1
```

Test de l'image publiée avec la stack complète :

```bash
git clone https://github.com/Keil-ENZO/devsecops-tp1.git && cd devsecops-tp1
API_TAG=1.0.0 docker compose up -d --no-build --wait --wait-timeout 120
curl -s http://localhost:5000/health    # {"status":"ok"}
curl -s http://localhost:5000/dbtest    # {"db_connection":"successful"}
docker compose down -v
```

---

## 2. Tableau comparatif Avant / Après

### Image API

| Critère | Avant | Après |
|---|---|---|
| Image de base | `python:3.10-slim`, tag mutable | `cgr.dev/chainguard/python@sha256:b6248c85…` |
| Build | mono-stage | multi-stage `-dev` → runtime |
| Poids | 178,5 Mo | **104,9 Mo** |
| Utilisateur | root, UID 0 | **65532**, non privilégié |
| Shell | oui, `sh` + `bash` | **absent** |
| Gestionnaire de paquets | `apt`, `pip` | **absent** |
| CVE Trivy totales | 185 | **0** |
| dont HIGH / CRITICAL | 47 / 0 | **0 / 0** |
| Efficience Dive | 97,80 %, 5,7 Mo gaspillés | **99,77 %**, 238 ko |
| Contenu de `/app` | code, `.git`, tests, Dockerfile, compose | `app.py` + `venv` |
| Healthcheck | aucun | exec Python stdlib |

### Image base de données

| Critère | Avant | Après |
|---|---|---|
| Image | `postgres:14-alpine`, tag mutable | `cgr.dev/chainguard/postgres@sha256:0c4eaf6c…` |
| Version | PostgreSQL 14 | PostgreSQL 18.6 |
| Poids | 284,6 Mo | 380,1 Mo |
| Utilisateur | root, puis `gosu` | **70** imposé dès le démarrage |
| Shell | oui, busybox | oui, requis par l'entrypoint |
| CVE Trivy totales | 47 | **0** |
| dont HIGH / CRITICAL | 21 / 1 | **0 / 0** |
| Efficience Dive | 99,89 % | 99,86 % |
| Port 5432 exposé | oui | **non** |
| Healthcheck | `CMD-SHELL` | exec `pg_isready` |

L'image DB grossit de 95 Mo.
Elle passe en revanche de 47 CVE à 0.
L'image Chainguard embarque un shell pour son script d'entrée.
Elle n'a ni `apk` ni `gosu`, source de 46 des 47 CVE initiales.

### Origine des CVE initiales

| Image | Cible Trivy | CRIT | HIGH | MED | LOW | UNK |
|---|---|---|---|---|---|---|
| API | OS Debian 13.7 | 0 | 44 | 58 | 61 | 2 |
| API | Paquets Python | 0 | 3 | 15 | 2 | 0 |
| DB | OS Alpine 3.24.2 | 0 | 0 | 1 | 0 | 0 |
| DB | Binaire `gosu`, Go stdlib 1.24.6 | 1 | 21 | 21 | 2 | 1 |

---

## 3. Justification des images de base retenues

### Image API : Chainguard Python

Trois candidats évalués avec Trivy :

| Image runtime | Taille | Python | CVE | HIGH+CRIT corrigeables |
|---|---|---|---|---|
| `gcr.io/distroless/python3-debian12:nonroot` | 65 Mo | 3.11.2 | 283 | **25** |
| `gcr.io/distroless/python3-debian13:nonroot` | 72 Mo | 3.13.5 | 159 | 0 |
| `cgr.dev/chainguard/python:latest` | 68 Mo | 3.14.8 | **0** | **0** |

Distroless Debian 12 aurait fait échouer la barrière Trivy.
Chainguard est retenu : 0 CVE, sans shell, utilisateur non root par défaut.

Le builder est `chainguard/python:latest-dev`.
Il fournit `pip` et un shell, uniquement pendant le build.
Les deux images placent Python dans `/usr/bin`.
Les liens symboliques du venv restent donc valides une fois copiés dans le runtime.

### Image DB : Chainguard PostgreSQL

Image imposée par la consigne.
Vérifié avant adoption : `pg_isready` présent, variables `POSTGRES_*` reconnues, 0 CVE.

### Immuabilité et reproductibilité

| Élément | Mécanisme |
|---|---|
| Images de base | Épinglage par digest `@sha256`, index multi-architecture |
| Builder et runtime | Digests relevés ensemble, même version de Python |
| Dépendances Python | Versions exactes `==` dans `requirements.txt` |
| Actions GitHub | SHA de commit complet, voir section 6 |
| Image Dive en CI | Digest `@sha256` |
| Image publiée | Archive scannée et testée poussée telle quelle, sans rebuild |

Chainguard gratuit ne propose que le tag `latest`.
Le digest est donc la seule référence immuable possible.
Hadolint accepte `:latest@sha256:` car le digest fige le contenu.

Digests utilisés :

```
cgr.dev/chainguard/python:latest-dev@sha256:894aed3297d91283e1fc4c542f5374a4b5f3726134fda7c94eaa539342be1e05
cgr.dev/chainguard/python:latest@sha256:b6248c85ba9b97e1e61b30197f309cc4d21661f889fefa5268f0a7bc530dad46
cgr.dev/chainguard/postgres:latest@sha256:0c4eaf6cb9bd65337d834f5ebfe79add4312ee2125ab584bf1fbc071abc6bb8f
```

### Dockerfile final

```dockerfile
FROM cgr.dev/chainguard/python:latest-dev@sha256:894aed32… AS builder
WORKDIR /app
COPY requirements.txt .
RUN python -m venv /app/venv \
    && /app/venv/bin/pip install --no-cache-dir -r requirements.txt \
    && /app/venv/bin/pip uninstall -y pip

FROM cgr.dev/chainguard/python:latest@sha256:b6248c85…
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY --from=builder /app/venv /app/venv
COPY app.py .
EXPOSE 5000
USER 65532
ENTRYPOINT ["/app/venv/bin/python", "app.py"]
```

| Choix | Effet |
|---|---|
| `requirements.txt` copié seul | La couche `pip install` reste en cache si seul le code change |
| `--no-cache-dir` | Aucun cache pip dans la couche |
| `pip uninstall -y pip` | Retire pip du venv. Sinon Trivy remonte 4 HIGH dans ses librairies vendorisées |
| `COPY --from=builder` | Seul le venv passe au runtime, aucun outil de build |
| `.dockerignore` | Exclut `.git`, `.env*`, caches, tests, logs, archives, docs |

---

## 4. Résolution des contraintes sans shell

### Le problème

Le healthcheck d'origine utilisait la forme shell :

```yaml
test: ["CMD-SHELL", "pg_isready -U testuser -d testdb"]
```

`CMD-SHELL` exécute `/bin/sh -c "..."`.
L'image API finale n'a pas de `/bin/sh`.
Un healthcheck shell y échoue systématiquement.
Le conteneur resterait `unhealthy`, et `depends_on` bloquerait la stack.

Même contrainte pour `curl` ou `wget` : ils sont absents de l'image.

### Sonde API : Python et sa bibliothèque standard

```yaml
healthcheck:
  test:
    - CMD
    - /usr/bin/python3
    - -c
    - "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=3).status == 200 else 1)"
  interval: 10s
  timeout: 5s
  retries: 3
  start_period: 10s
```

| Choix | Raison |
|---|---|
| Forme `CMD` | Docker lance le binaire directement, sans shell |
| `/usr/bin/python3` | Seul exécutable disponible dans le runtime |
| `urllib.request` | Bibliothèque standard, aucune dépendance à installer |
| Hors venv | La sonde ne dépend pas des paquets applicatifs |
| `127.0.0.1` | Évite la résolution DNS de `localhost` |
| `timeout=3` | Une API bloquée échoue avant le `timeout` Docker de 5 s |
| `sys.exit(0 ou 1)` | Code de retour attendu par Docker |

Une erreur réseau lève une exception.
Python sort alors avec le code 1, compté comme un échec.

### Sonde PostgreSQL : `pg_isready` en exec

```yaml
healthcheck:
  test: ["CMD", "pg_isready", "-U", "testuser", "-d", "testdb"]
  interval: 10s
  timeout: 5s
  retries: 5
  start_period: 30s
```

`pg_isready` est le client d'administration livré dans l'image Chainguard.
La forme `CMD` l'appelle sans passer par un shell.
Il interroge le socket Unix local du serveur.

### Exécution de la DB en non-root

```yaml
user: "70:70"
volumes:
  - db-data-test:/var/lib/postgresql
environment:
  PGDATA: /var/lib/postgresql/data
```

Le conteneur DB démarre directement en UID 70.
Aucune bascule depuis root n'a lieu.

Problème rencontré : `initdb: could not change permissions of directory`.
Le dossier `data` n'existe pas dans l'image.
Docker créait donc le point de montage en root.
Solution : monter le volume sur le parent, déjà possédé par l'UID 70.
`initdb` crée ensuite `data` lui-même.

### Synchronisation de démarrage

```yaml
depends_on:
  db:
    condition: service_healthy
```

L'API ne démarre qu'une fois `pg_isready` validé.
En CI, `docker compose up --wait --wait-timeout 120` attend les deux sondes.
La commande échoue si un service n'est pas sain sous 120 s.

---

## 5. Journal des remédiations de dépendances & Qualité

### 5.1 Flake8

Configuration fournie, conservée sans modification :

```ini
[flake8]
max-line-length = 88
ignore = E203, W503, E302, E305, W293, W292, W391
exclude = migrations, venv
```

Avec cette configuration, le code d'origine sortait déjà vierge.
Les règles ignorées masquaient 11 violations PEP 8 réelles.
Elles ont toutes été corrigées.
Le code passe désormais Flake8 **avec et sans** les exclusions.

| Code | Nb | Fichier | Violation | Correction |
|---|---|---|---|---|
| E302 | 4 | `app.py` | 1 ligne vide avant une fonction au lieu de 2 | Ajout de lignes vides |
| E302 | 4 | `test_app.py` | idem | idem |
| W293 | 1 | `app.py:46` | Ligne vide contenant des espaces | Espaces supprimés |
| W391 | 1 | `app.py:50` | Ligne vide en fin de fichier | Ligne supprimée |
| W292 | 1 | `test_app.py:23` | Pas de retour à la ligne final | Retour ajouté |

### 5.2 Vulnérabilités du `requirements.txt` d'origine

```
Flask==2.3.2
Werkzeug==2.3.3
pytest==7.4.0
psycopg2-binary
```

`pip-audit` : 19 entrées, 11 CVE distinctes, 3 paquets.

| Paquet | Version | CVE | Sévérité | Corrigé en |
|---|---|---|---|---|
| Werkzeug | 2.3.3 | CVE-2024-34069 | HIGH | 3.0.3 |
| Werkzeug | 2.3.3 | CVE-2023-46136 | MEDIUM | 2.3.8 |
| Werkzeug | 2.3.3 | CVE-2024-49766 | MEDIUM | 3.0.6 |
| Werkzeug | 2.3.3 | CVE-2024-49767 | MEDIUM | 3.0.6 |
| Werkzeug | 2.3.3 | CVE-2025-66221 | MEDIUM | 3.1.4 |
| Werkzeug | 2.3.3 | CVE-2026-21860 | MEDIUM | 3.1.5 |
| Werkzeug | 2.3.3 | CVE-2026-27199 | MEDIUM | 3.1.6 |
| Werkzeug | 2.3.3 | CVE-2026-102598 | MEDIUM | 3.1.9 |
| Werkzeug | 2.3.3 | PYSEC-2026-3417 | n/c | 3.0.6 |
| Flask | 2.3.2 | CVE-2026-27205 | LOW | 3.1.3 |
| pytest | 7.4.0 | CVE-2025-71176 | MEDIUM | 9.0.3 |

Autres défauts :

- `psycopg2-binary` sans version : build non reproductible.
- Outils vulnérables présents dans l'ancienne image runtime : `pip` 23.0.1, 7 CVE ; `wheel` 0.45.1, HIGH ; `setuptools` 79.0.1 ; `jaraco.context` 5.3.0, HIGH.

### 5.3 Montées de versions

| Paquet | Avant | Après | Justification |
|---|---|---|---|
| Werkzeug | 2.3.3 | **3.1.9** | Seule version corrigeant les 9 CVE, dont CVE-2026-102598 |
| Flask | 2.3.2 | **3.1.3** | Corrige CVE-2026-27205. Flask 3.1 requiert Werkzeug ≥ 3.1 |
| pytest | 7.4.0 | **9.1.1** | Corrige CVE-2025-71176 |
| psycopg2-binary | non épinglé | **2.9.13** | Version figée. Wheel disponible pour Python 3.14 |

Compatibilité vérifiée :

- API inchangée : `Flask`, `jsonify`, `psycopg2.connect` fonctionnent à l'identique.
- `/dbtest` validé contre PostgreSQL 18.6.
- 3 tests pytest passent.
- `pip-audit` final : `No known vulnerabilities found`.
- `pip`, `wheel` et `setuptools` sont absents du runtime final.

---

## 6. Sécurisation de la chaîne CI/CD

Fichier : `.github/workflows/ci.yaml`.
Déclencheurs : `push` et `pull_request` sur `main`, et tags `v*.*.*`.

```
lint-python ─┐
(Flake8)     ├─> build ──┬─> trivy ────────┐
lint-docker ─┘  + Dive   └─> integration ──┴─> release
(Hadolint)                                     (tag v*.*.* uniquement)
```

| Job | Barrière bloquante |
|---|---|
| `lint-python` | `flake8 --config .flake8 .` |
| `lint-docker` | Hadolint avec `.hadolint.yaml`, seuil `warning` |
| `build` | Build BuildKit, puis Dive : efficience < 80 % ou gaspillage utilisateur > 20 % |
| `trivy` | Image + `requirements.txt` : `HIGH,CRITICAL`, `ignore-unfixed`, `exit-code: 1` |
| `integration` | `compose up --wait`, `curl /health` et `/dbtest`, pytest, `down -v` systématique |
| `release` | `needs: [trivy, integration]`, publication GHCR |

### Permissions minimales

```yaml
permissions: {}            # niveau workflow : aucun droit
```

| Job | Permissions |
|---|---|
| lint, build, trivy, integration | `contents: read` |
| release | `contents: read`, `packages: write` |

Le `GITHUB_TOKEN` n'a aucun droit par défaut.
Seul `release` peut écrire sur GHCR.
Un job de lint ou de test compromis ne peut rien publier.
`persist-credentials: false` évite de laisser le token dans `.git` après le checkout.
L'authentification GHCR utilise le jeton natif `secrets.GITHUB_TOKEN`, sans secret personnel.

### Pinning SHA des actions

Un tag comme `v4` est mobile : son propriétaire peut le déplacer.
Un dépôt d'action compromis peut ainsi injecter du code dans tous les pipelines qui l'utilisent.
L'incident `tj-actions/changed-files` de mars 2025 a exploité ce mécanisme.
Un SHA de commit est immuable.

| Action | Version | SHA |
|---|---|---|
| actions/checkout | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| actions/setup-python | v7.0.0 | `5fda3b95a4ea91299a34e894583c3862153e4b97` |
| actions/upload-artifact | v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| actions/download-artifact | v8.0.2 | `9000827ccba6bdab643e8b6fd33ac0654aef8333` |
| docker/setup-buildx-action | v4.4.1 | `f87e5991a6d7451dcb8d9637bfbc97413f497069` |
| docker/metadata-action | v6.2.0 | `dc802804100637a589fabce1cb79ff13a1411302` |
| docker/build-push-action | v7.4.0 | `c3c9e263c25d99ce0380d002d59b67737d91b0dc` |
| docker/login-action | v4.6.0 | `dbcb813823bdd20940b903addbd779551569679f` |
| hadolint/hadolint-action | v3.5.0 | `06be81baf89a55ffd0e24b8f04a4185738dd3387` |
| aquasecurity/trivy-action | v0.36.0 | `ed142fd0673e97e23eac54620cfb913e5ce36c25` |

L'image `wagoodman/dive:v0.13.1` est épinglée par digest `sha256:f1886e6c…`.

### Traçabilité de l'artefact

L'image est construite une seule fois dans `build`, puis transmise en artefact.
Trivy, les tests d'intégration et la release utilisent cette même archive.
L'image publiée est donc exactement celle qui a été validée.
Le label OCI `org.opencontainers.image.source` relie le package au dépôt.
Les labels `revision` et `created` identifient le commit et la date de build.

### Stratégie SemVer

Publication uniquement sur un tag Git `vMAJEUR.MINEUR.CORRECTIF`.

| Tag Git | Tags publiés |
|---|---|
| `v1.0.0` | `1.0.0`, `1.0`, `1` |
| `v1.2.3` | `1.2.3`, `1.2`, `1` |
| `v0.4.1` | `0.4.1`, `0.4` |

- `1.0.0` : version exacte, immuable.
- `1.0` : suit les correctifs de la ligne 1.0.
- `1` : suit toute la version majeure 1.
- Pas de tag majeur pour `0.x` : en SemVer, la série 0 n'est pas stable.

---

## 7. Preuves d'exécution

### Flake8 vierge

```
$ flake8 --config .flake8 .
$ echo $?
0

$ flake8 --isolated --max-line-length 88 app.py test_app.py
$ echo $?
0
```

### Hadolint vierge

```
$ hadolint -c .hadolint.yaml Dockerfile
$ echo $?
0
```

`.hadolint.yaml` :

```yaml
failure-threshold: warning
trustedRegistries:
  - docker.io
  - gcr.io
  - cgr.dev
  - ghcr.io
disable-ignore-pragma: true
override:
  error:
    # Sécurité
    - DL3002 # dernier USER non-root
    - DL3006 # tag explicite obligatoire sur FROM
    - DL3007 # :latest interdit sans digest immuable
    - DL4006 # set -o pipefail obligatoire avant un pipe
    # Règles standards sans dérogation
    - DL3025 # forme JSON exec obligatoire pour CMD / ENTRYPOINT
    - DL3042 # éviter le cache pip (--no-cache-dir)
    - DL3008 # versions épinglées apt-get
    - DL3009 # nettoyage cache listes apt
    - DL3015 # éviter les paquets recommandés
    - DL3019 # apk --no-cache
    - DL3020 # COPY au lieu de ADD
    - DL3021 # formatage slash pour COPY multi-sources
    - DL3022 # référence d'étape FROM valide pour COPY --from
    - DL3023 # pas d'auto-référence d'étape
    - DL3003 # WORKDIR au lieu de cd
    - SC2086 # protection des variables shell (double-quoting)
    - SC2154 # variable non assignée
```

### Dive ≥ 80 %

```
$ dive --ci --lowestEfficiency=0.8 --highestUserWastedPercent=0.2 docker-archive://image.tar
  efficiency: 99.7734 %
  wastedBytes: 238044 bytes (238 kB)
  userWastedPercent: 0.3603 %
  PASS: highestUserWastedPercent
  PASS: lowestEfficiency
Result:PASS [Total:3] [Passed:2] [Failed:0] [Warn:0] [Skipped:1]
```

### Trivy clean

```
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 devsecops-tp1-api
$ echo $?
0
```

```
│ api:after (wolfi 20230201)                                │   wolfi    │ 0 │
│ .../flask-3.1.3.dist-info/METADATA                        │ python-pkg │ 0 │
│ .../werkzeug-3.1.9.dist-info/METADATA                     │ python-pkg │ 0 │
│ .../psycopg2_binary-2.9.13.dist-info/METADATA             │ python-pkg │ 0 │
│ .../pytest-9.1.1.dist-info/METADATA                       │ python-pkg │ 0 │
```

```
$ pip-audit -r requirements.txt
No known vulnerabilities found
```

### Absence de shell et utilisateur

```
$ docker run --rm --entrypoint sh ghcr.io/keil-enzo/devsecops-tp1-api:1.0.0 -c id
docker: Error response from daemon: failed to create task for container: [...]
exec: "sh": executable file not found in $PATH

$ docker inspect -f '{{.Config.User}}' ghcr.io/keil-enzo/devsecops-tp1-api:1.0.0
65532
```

### Statut sain sous Compose

```
$ docker compose up -d --wait --wait-timeout 120
$ docker compose ps
SERVICE      STATUS
api-python   Up 5 seconds (healthy)
db           Up 11 seconds (healthy)

$ curl -s http://localhost:5000/health
{"status":"ok"}
$ curl -s http://localhost:5000/dbtest
{"db_connection":"successful"}
```

### Tests d'intégration

```
$ DB_HOST=127.0.0.1 pytest -v
test_app.py::test_health PASSED                                          [ 33%]
test_app.py::test_hello PASSED                                           [ 66%]
test_app.py::test_dbtest PASSED                                          [100%]
============================== 3 passed in 0.85s ===============================
```

### Pipeline GitHub Actions

| Déclencheur | Run | Résultat |
|---|---|---|
| Pull request #1 | [37779582120](https://github.com/Keil-ENZO/devsecops-tp1/actions/runs/37779582120) | ✅ success |
| Push sur `main` | [37779993568](https://github.com/Keil-ENZO/devsecops-tp1/actions/runs/37779993568) | ✅ success, release ignorée car sans tag |
| Tag `v1.0.0` | [37783928241](https://github.com/Keil-ENZO/devsecops-tp1/actions/runs/37783928241) | ✅ success |

Détail du run `v1.0.0` :

```
Lint Python (Flake8): success
Lint Dockerfile (Hadolint): success
Build & métrologie des couches (Dive): success
Vulnérabilités (Trivy): success
Tests d'intégration (Compose): success
Publication GHCR: success
```

### Publication GHCR confirmée

Extrait du job `Publication GHCR` :

```
The push refers to repository [ghcr.io/keil-enzo/devsecops-tp1-api]
ad34bb2d9fea: Pushed
94d60d793334: Pushed
[...]
cf2c94266c56: Pushed
```

Pull anonyme, sans authentification :

```
$ docker logout ghcr.io
Removing login credentials for ghcr.io

$ docker pull ghcr.io/keil-enzo/devsecops-tp1-api:1.0.0
1.0.0: Pulling from keil-enzo/devsecops-tp1-api
6d4bd3a74295: Pull complete
[...]
8de010ef9caf: Pull complete
Digest: sha256:a779745c8ea8ce40fecd6fc019a362bd4d141fadb7e679b429b53ef504a33418
Status: Downloaded newer image for ghcr.io/keil-enzo/devsecops-tp1-api:1.0.0
```

Labels OCI de l'image publiée :

```
org.opencontainers.image.source   = https://github.com/Keil-ENZO/devsecops-tp1
org.opencontainers.image.revision = 009e7e85cd04e1d503ed10932752cb87811aa195
org.opencontainers.image.version  = v1.0.0
org.opencontainers.image.created  = 2026-10-08T13:23:41.948Z
```

Image publiée testée dans la stack Compose :

```
$ API_TAG=1.0.0 docker compose up -d --no-build --wait --wait-timeout 120
$ docker compose ps
SERVICE      IMAGE                                       STATUS
api-python   ghcr.io/keil-enzo/devsecops-tp1-api:1.0.0   Up 5 seconds (healthy)
db           cgr.dev/chainguard/postgres:latest@sha256:0c4eaf6c…   Up 11 seconds (healthy)

$ curl -s http://localhost:5000/health
{"status":"ok"}
$ curl -s http://localhost:5000/dbtest
{"db_connection":"successful"}
```

---

# TP 2 : Industrialisation de la chaîne

## Étape 1 : Build, secrets et multi-architecture

### A. Cache pip persistant hors couches

Le Dockerfile active la syntaxe BuildKit étendue :

```dockerfile
# syntax=docker/dockerfile:1.27@sha256:4edf897a…
```

L'installation monte un cache dédié géré par BuildKit :

```dockerfile
RUN --mount=type=cache,id=pip,target=/home/nonroot/.cache/pip,uid=65532,gid=65532,sharing=locked \
    ...
    && /app/venv/bin/pip install -r requirements.txt
```

`--no-cache-dir` disparaît. Le cache vit hors de l'image.
Hadolint accepte ce motif : DL3042 reste vert.

Preuve : ajout de `six==1.17.0` puis rebuild.

```
Collecting Flask==3.1.3          Using cached flask-3.1.3-py3-none-any.whl
Collecting psycopg2-binary       Using cached psycopg2_binary-2.9.13-…whl
Collecting six==1.17.0           Downloading six-1.17.0-py2.py3-none-any.whl
```

Seule la nouvelle dépendance est téléchargée.
L'export du conteneur ne contient aucun dossier `.cache` ni `pip`.

### B. Secret de build en tmpfs

Le jeton est monté uniquement pendant le `RUN` :

```dockerfile
--mount=type=secret,id=pip_token,required=true,uid=65532,mode=0400 \
test -s /run/secrets/pip_token \
```

Aucun `ARG`, aucun `ENV`.
Le build échoue si le fichier manque ou est vide.
Le fichier local `secrets/pip_token` est exclu par `.gitignore` et `.dockerignore`.

Génération locale :

```bash
mkdir -p secrets && openssl rand -hex 32 > secrets/pip_token && chmod 600 secrets/pip_token
```

En CI, le jeton vient du secret GitHub `PIP_TOKEN`.

Vérifications :

| Contrôle | Résultat |
|---|---|
| `docker history --no-trunc` grep du jeton | 0 occurrence |
| `docker image inspect` grep du jeton | 0 occurrence |
| `trivy image --scanners secret` | Clean |
| Fichier absent | `failed to stat` |
| Fichier vide | `exit code: 1` |

### C. Bake HCL multi-plateforme

Tout est décrit dans `docker-bake.hcl`.

| Variable | Défaut | Rôle |
|---|---|---|
| `REGISTRY` | `ghcr.io/keil-enzo` | Registre cible |
| `IMAGE` | `devsecops-tp1-api` | Nom du dépôt |
| `VERSION` | `local` | `1.2.3` produit `1.2.3`, `1.2`, `1` |
| `REVISION` | vide | SHA Git en label OCI |
| `PIP_TOKEN_FILE` | `secrets/pip_token` | Source du secret |

| Cible | Plateformes | Sortie | Cache |
|---|---|---|---|
| `local` | hôte | `docker` | import |
| `ci` | `linux/amd64` | archive pour Dive, Trivy, Compose | import + export `buildcache-ci` |
| `release` | `linux/amd64`, `linux/arm64` | push GHCR | import + export `buildcache` |

Le cache registre est exporté en `mode=max`.
Les étages intermédiaires sont donc réutilisables sur runner éphémère.

```bash
docker buildx bake -f docker-bake.hcl            # image locale
VERSION=1.1.0 docker buildx bake -f docker-bake.hcl release
docker buildx imagetools inspect ghcr.io/keil-enzo/devsecops-tp1-api:1.1.0
```

Index OCI obtenu :

```
MediaType: application/vnd.oci.image.index.v1+json
  Platform:  linux/amd64
  Platform:  linux/arm64
```

Le job `release` lance QEMU, puis `bake release` sur tag `v*.*.*`.

## Étape 2 : Publication, signature et attestation

### Publication immuable multi-architecture

Une release n'est déclenchée que par un tag SemVer `vX.Y.Z`. La cible Bake
`release` publie un index OCI pour `linux/amd64` et `linux/arm64`. Le workflow
écrit les métadonnées Buildx dans un fichier JSON, valide la forme du digest
`sha256` retourné, puis utilise exclusivement la référence immuable
`IMAGE@sha256:...` pour toutes les opérations cryptographiques.

### Secrets Cosign requis

La signature utilise la paire de clés dédiée dont la partie publique est
versionnée dans `cosign.pub`. La clé privée et son mot de passe ne doivent
jamais être ajoutés au dépôt. Ils doivent être enregistrés dans GitHub :

```bash
gh secret set COSIGN_PRIVATE_KEY < cosign.key
read -rs COSIGN_PASSWORD
printf '%s' "$COSIGN_PASSWORD" | gh secret set COSIGN_PASSWORD
unset COSIGN_PASSWORD
```

Si la clé privée correspondant au fichier `cosign.pub` est perdue, il faut
générer une nouvelle paire avec `cosign generate-key-pair`, remplacer
`cosign.pub`, puis enregistrer la nouvelle clé privée dans les secrets GitHub.

### Signature et attestation CycloneDX

Après la publication, le job `release` :

1. récupère le digest de l'index depuis `buildx bake --metadata-file` ;
2. signe l'index multi-architecture avec Cosign 3.1.4 ;
3. attache `sbom.cdx.json` comme attestation signée de type CycloneDX.

Vérification publique, en remplaçant la valeur du digest par celle de la
release :

```bash
IMAGE='ghcr.io/keil-enzo/devsecops-tp1-api@sha256:<digest>'

cosign verify --key cosign.pub "$IMAGE"
cosign verify-attestation --key cosign.pub --type cyclonedx "$IMAGE"
cosign download attestation "$IMAGE" \
  | jq -r '.payload' \
  | base64 -d \
  | jq '.predicate'
```
