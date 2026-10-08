# TP DevSecOps : Audit et durcissement d'une stack Flask + PostgreSQL

Rapport d'audit et d'architecture.
L'état **Avant** est mesuré sur le commit initial `9c6c1d4`.
Les cellules `À COMPLÉTER` correspondent à l'état **Après** durcissement.

Outils utilisés pour l'audit initial :

| Outil | Rôle |
|---|---|
| Hadolint | Lint du Dockerfile |
| Flake8 | Qualité du code Python, PEP 8 |
| pip-audit | Vulnérabilités du `requirements.txt` |
| Trivy | CVE OS et librairies des images |
| Dive | Efficience des couches d'image |

---

## 1. Liens publics des packages GHCR

| Image | Package GHCR |
|---|---|
| API Flask | `À COMPLÉTER` https://github.com/Keil-ENZO/devsecops-tp1/pkgs/container/devsecops-tp1-api |
| Base PostgreSQL | `À COMPLÉTER` https://github.com/Keil-ENZO/devsecops-tp1/pkgs/container/devsecops-tp1-db |

Commandes de récupération avec tag sémantique :

```bash
docker pull ghcr.io/keil-enzo/devsecops-tp1-api:vX.Y.Z   # À COMPLÉTER
docker pull ghcr.io/keil-enzo/devsecops-tp1-db:vX.Y.Z    # À COMPLÉTER
```

Test rapide de l'image publiée :

```bash
# À COMPLÉTER
docker run --rm -p 5000:5000 ghcr.io/keil-enzo/devsecops-tp1-api:vX.Y.Z
curl -s http://localhost:5000/health
```

**État initial :** aucun pipeline CI/CD, aucune image publiée.

---

## 2. Tableau comparatif Avant / Après

### Image API

| Critère | Avant | Après |
|---|---|---|
| Image de base | `python:3.10-slim`, tag mutable | À COMPLÉTER |
| Poids | **178,5 Mo** | À COMPLÉTER |
| Utilisateur d'exécution | **root**, uid 0 | À COMPLÉTER |
| Shell présent | **Oui**, `/bin/sh` et `bash` | À COMPLÉTER |
| CVE Trivy totales | **185** | À COMPLÉTER |
| dont CRITICAL / HIGH | 0 / **47** | À COMPLÉTER |
| dont MEDIUM / LOW / UNKNOWN | 73 / 63 / 2 | À COMPLÉTER |
| Efficience Dive | 97,80 %, 5,7 Mo gaspillés | À COMPLÉTER |
| Healthcheck | **Aucun** | À COMPLÉTER |
| Hadolint | 0 alerte | À COMPLÉTER |

### Image base de données

| Critère | Avant | Après |
|---|---|---|
| Image de base | `postgres:14-alpine`, tag mutable | À COMPLÉTER |
| Poids | **284,6 Mo** | À COMPLÉTER |
| Utilisateur d'exécution | **root** au démarrage, bascule via `gosu` | À COMPLÉTER |
| Shell présent | **Oui**, `/bin/sh` busybox | À COMPLÉTER |
| CVE Trivy totales | **47** | À COMPLÉTER |
| dont CRITICAL / HIGH | **1 / 21** | À COMPLÉTER |
| dont MEDIUM / LOW / UNKNOWN | 22 / 2 / 1 | À COMPLÉTER |
| Efficience Dive | 99,89 %, 545 ko gaspillés | À COMPLÉTER |
| Healthcheck | `CMD-SHELL pg_isready`, dépend du shell | À COMPLÉTER |

### Répartition des CVE initiales

| Image | Cible Trivy | CRIT | HIGH | MED | LOW | UNK |
|---|---|---|---|---|---|---|
| API | OS Debian 13.7 | 0 | 44 | 58 | 61 | 2 |
| API | Paquets Python | 0 | 3 | 15 | 2 | 0 |
| DB | OS Alpine 3.24.2 | 0 | 0 | 1 | 0 | 0 |
| DB | Binaire `gosu`, Go stdlib 1.24.6 | 1 | 21 | 21 | 2 | 1 |

Constat : sur l'image DB, **la quasi totalité des CVE vient de `gosu`**.
Ce binaire sert uniquement à abandonner les privilèges root.
La CVE critique est `CVE-2025-68121` dans la stdlib Go.

---

## 3. Justification des images de base retenues

### Problèmes de l'existant

- `python:3.10-slim` embarque Debian complet : apt, shell, coreutils.
- 163 CVE sur 185 viennent des paquets OS, pas de l'application.
- `pip`, `setuptools`, `wheel` restent présents au runtime.
- Tags mutables : `3.10-slim` et `14-alpine` changent sans prévenir.
- Aucun digest épinglé : build non reproductible.
- Build monostage : outils de build livrés en production.
- Pas de `.dockerignore` : `COPY . .` copie `.git`, tests, Dockerfile.

Contenu réel de `/app` dans l'image initiale :

```
.flake8  .git  Dockerfile  LICENSE  app.py  docker-compose.yml  requirements.txt  test_app.py
```

### Choix retenus

À COMPLÉTER :

- Image runtime API : Distroless ou Chainguard, justification.
- Image runtime DB : Chainguard PostgreSQL ou autre, justification.
- Stratégie multi-stage : builder complet, runtime minimal.

### Immuabilité et reproductibilité

À COMPLÉTER :

- Épinglage par digest `@sha256:...` des images de base.
- Versions exactes dans `requirements.txt`, idéalement avec hashes.
- Mécanisme de mise à jour des digests.

Digest observé lors de l'audit initial :

```
postgres:14-alpine -> sha256:4ea9e5ed06591da7ea23eb65465e8d3187fe79f4d5ec3ae976d29a33b013e77a
```

---

## 4. Résolution des contraintes sans shell

### Existant

- **API** : aucun healthcheck défini.
  Compose voit le conteneur `Up` même si Flask ne répond plus.
- **DB** : healthcheck en `CMD-SHELL` :

```yaml
test: ["CMD-SHELL", "pg_isready -U testuser -d testdb"]
```

`CMD-SHELL` lance `/bin/sh -c`.
Sur une image sans shell, ce healthcheck échoue systématiquement.
Le `depends_on: service_healthy` de l'API bloquerait alors le démarrage.

### Implémentation retenue

À COMPLÉTER :

- **API** : healthcheck en forme exec `CMD`, sans shell.
  Exemple : script Python natif qui interroge `/health`.
- **DB** : appel direct du binaire `pg_isready` en forme `CMD`.
- Extrait du `docker-compose.yml` final.

---

## 5. Journal des remédiations de dépendances & Qualité

### 5.1 Flake8

Le fichier `.flake8` d'origine masque les erreurs :

```ini
ignore = E203, W503, E302, E305, W293, W292, W391
```

Avec cette configuration, Flake8 sort vide. Résultat trompeur.
Sans les `ignore` abusifs, 11 violations apparaissent :

```
$ flake8 --isolated --max-line-length 88 app.py test_app.py
app.py:13:1: E302 expected 2 blank lines, found 1
app.py:17:1: E302 expected 2 blank lines, found 1
app.py:21:1: E302 expected 2 blank lines, found 1
app.py:31:1: E302 expected 2 blank lines, found 1
app.py:46:1: W293 blank line contains whitespace
app.py:50:1: W391 blank line at end of file
test_app.py:4:1: E302 expected 2 blank lines, found 1
test_app.py:10:1: E302 expected 2 blank lines, found 1
test_app.py:14:1: E302 expected 2 blank lines, found 1
test_app.py:18:1: E302 expected 2 blank lines, found 1
test_app.py:23:58: W292 no newline at end of file
```

| Code | Nombre | Signification |
|---|---|---|
| E302 | 8 | 2 lignes vides attendues avant une fonction |
| W293 | 1 | Ligne vide contenant des espaces |
| W391 | 1 | Ligne vide en fin de fichier |
| W292 | 1 | Pas de retour à la ligne final |

Corrections appliquées : À COMPLÉTER.

### 5.2 Vulnérabilités du `requirements.txt` d'origine

```
Flask==2.3.2
Werkzeug==2.3.3
pytest==7.4.0
psycopg2-binary
```

Problèmes structurels :

- `psycopg2-binary` sans version : build non reproductible.
  Version résolue lors de l'audit : 2.9.13.
- `pytest` installé dans l'image de production.
- Aucun hash de vérification `--hash=sha256:...`.

Résultat `pip-audit -r requirements.txt` : **19 entrées, 3 paquets**.

| Paquet | Version | CVE | Sévérité | Correctif |
|---|---|---|---|---|
| Werkzeug | 2.3.3 | CVE-2024-34069 | HIGH | 3.0.3 |
| Werkzeug | 2.3.3 | CVE-2023-46136 | MEDIUM | 2.3.8 / 3.0.1 |
| Werkzeug | 2.3.3 | CVE-2024-49766 | MEDIUM | 3.0.6 |
| Werkzeug | 2.3.3 | CVE-2024-49767 | MEDIUM | 3.0.6 |
| Werkzeug | 2.3.3 | CVE-2025-66221 | MEDIUM | 3.1.4 |
| Werkzeug | 2.3.3 | CVE-2026-21860 | MEDIUM | 3.1.5 |
| Werkzeug | 2.3.3 | CVE-2026-27199 | MEDIUM | 3.1.6 |
| Werkzeug | 2.3.3 | CVE-2026-102598 | MEDIUM | 3.1.9 |
| Flask | 2.3.2 | CVE-2026-27205 | LOW | 3.1.3 |
| pytest | 7.4.0 | CVE-2025-71176 | MEDIUM | 9.0.3 |

Paquets d'outillage vulnérables présents dans l'image runtime :

| Paquet | Version | CVE | Sévérité | Correctif |
|---|---|---|---|---|
| wheel | 0.45.1 | CVE-2026-24049 | HIGH | 0.46.2 |
| jaraco.context | 5.3.0 | CVE-2026-23949 | HIGH | 6.1.0 |
| pip | 23.0.1 | 7 CVE dont CVE-2025-8869 | MEDIUM / LOW | 26.2.0 |
| setuptools | 79.0.1 | CVE-2026-59890 | MEDIUM | 83.0.0 |

Ces paquets n'ont aucune utilité au runtime.

### 5.3 Montées de versions

À COMPLÉTER :

| Paquet | Avant | Après | Justification |
|---|---|---|---|
| Flask | 2.3.2 | | |
| Werkzeug | 2.3.3 | | |
| psycopg2-binary | non épinglé | | |
| pytest | 7.4.0 | | Déplacé en dépendance de dev |

---

## 6. Sécurisation de la chaîne CI/CD

### Existant

- Aucun workflow GitHub Actions.
- Aucun lint, scan ou test automatisé.
- Aucune publication d'image ni versionnement.
- Identifiants DB en clair dans `app.py` et `docker-compose.yml`.

### Politique retenue

À COMPLÉTER :

- **Permissions minimales** : `permissions: {}` global, puis par job.
  Exemple : `contents: read`, `packages: write` sur le seul job de publication.
- **Pinning SHA** : chaque action référencée par commit SHA complet.
  Un tag `v4` peut être déplacé par un attaquant. Un SHA non.
- **SemVer** : tags `vX.Y.Z` déclenchant la publication.
  Tags générés : `X.Y.Z`, `X.Y`, `sha-<commit>`.
- Étapes du pipeline : Flake8, Hadolint, build, Dive, Trivy, tests, push.

---

## 7. Preuves d'exécution

### 7.1 État initial

**Hadolint** sur le Dockerfile d'origine :

```
$ hadolint Dockerfile
$ echo $?
0
```

Aucune alerte. Le Dockerfile reste pourtant non sécurisé : root, monostage, pas de digest.
Hadolint ne suffit donc pas seul.

**Dive** :

```
devsecops-tp1-api:before
  efficiency: 97.8037 %
  wastedBytes: 5651788 bytes (5.7 MB)
  userWastedPercent: 7.2577 %

postgres:14-alpine
  efficiency: 99.8904 %
  wastedBytes: 545018 bytes (545 kB)
  userWastedPercent: 0.1975 %
```

**Trivy** :

```
devsecops-tp1-api:before  TOTAL 185  HIGH 47  MEDIUM 73  LOW 63  UNKNOWN 2
postgres:14-alpine        TOTAL 47   CRITICAL 1  HIGH 21  MEDIUM 22  LOW 2  UNKNOWN 1
```

**Utilisateur et shell** :

```
$ docker run --rm --entrypoint sh devsecops-tp1-api:before -c id
uid=0(root) gid=0(root) groups=0(root)

$ docker run --rm --entrypoint sh postgres:14-alpine -c id
uid=0(root) gid=0(root) groups=0(root),...
```

**Compose** :

```
SERVICE      IMAGE                STATUS
api-python   tpavant-api-python   Up 30 seconds
db           postgres:14-alpine   Up 35 seconds (healthy)

$ curl -s localhost:5000/health
{"status":"ok"}
$ curl -s localhost:5000/dbtest
{"db_connection":"successful"}
```

L'API n'affiche aucun statut de santé : aucun healthcheck défini.

### 7.2 État final

À COMPLÉTER :

- [ ] Flake8 vierge avec configuration stricte
- [ ] Hadolint vierge
- [ ] Dive, efficience ≥ 80 %
- [ ] Trivy clean
- [ ] `docker compose ps` avec les deux services `healthy`
- [ ] Tests d'intégration `pytest -m integration` validés
- [ ] Publication GHCR confirmée, lien du run GitHub Actions
