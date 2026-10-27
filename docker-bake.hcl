# Définition déclarative des builds (docker buildx bake).
#   docker buildx bake            -> image locale, plateforme de l'hôte
#   docker buildx bake ci         -> archive amd64 pour Dive / Trivy / Compose
#   docker buildx bake release    -> index multi-arch amd64 + arm64 poussé sur GHCR

variable "REGISTRY" {
  default = "ghcr.io/keil-enzo"
}

variable "IMAGE" {
  default = "devsecops-tp1-api"
}

# Version publiée : "1.2.3" génère les tags 1.2.3, 1.2 et 1 (pas de majeur en 0.x).
variable "VERSION" {
  default = "local"
}

variable "REVISION" {
  default = ""
}

variable "SOURCE_URL" {
  default = "https://github.com/Keil-ENZO/devsecops-tp1"
}

# Fichier local du jeton (ignoré par Git et par le contexte de build).
variable "PIP_TOKEN_FILE" {
  default = "secrets/pip_token"
}

variable "CI_OUTPUT" {
  default = "image.tar"
}

function "repo" {
  params = []
  result = "${REGISTRY}/${IMAGE}"
}

function "semver_tags" {
  params = [version]
  result = length(regexall("^[0-9]+\\.[0-9]+\\.[0-9]+$", version)) == 0 ? [
    "${repo()}:${version}",
    ] : compact([
      "${repo()}:${version}",
      "${repo()}:${join(".", slice(split(".", version), 0, 2))}",
      split(".", version)[0] == "0" ? "" : "${repo()}:${split(".", version)[0]}",
  ])
}

# Cache externe par cible : la cible ci (amd64 seul) n'écrase pas le cache multi-arch.
function "cache_from" {
  params = []
  result = [
    "type=registry,ref=${repo()}:buildcache",
    "type=registry,ref=${repo()}:buildcache-ci",
  ]
}

function "cache_to" {
  params = [suffix]
  result = ["type=registry,ref=${repo()}:${suffix},mode=max,ignore-error=true"]
}

target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
  secret     = ["type=file,id=pip_token,src=${PIP_TOKEN_FILE}"]
  cache-from = cache_from()
  labels = {
    "org.opencontainers.image.source"   = SOURCE_URL
    "org.opencontainers.image.version"  = VERSION
    "org.opencontainers.image.revision" = REVISION
    "org.opencontainers.image.licenses" = "MIT"
  }
}

group "default" {
  targets = ["local"]
}

target "local" {
  inherits = ["_common"]
  tags     = ["${repo()}:${VERSION}"]
  output   = ["type=docker"]
}

target "ci" {
  inherits  = ["_common"]
  platforms = ["linux/amd64"]
  tags      = semver_tags(VERSION)
  cache-to  = cache_to("buildcache-ci")
  output    = ["type=docker,dest=${CI_OUTPUT}"]
}

target "release" {
  inherits  = ["_common"]
  platforms = ["linux/amd64", "linux/arm64"]
  tags      = semver_tags(VERSION)
  cache-to  = cache_to("buildcache")
  # Annotation au niveau de l'index : GHCR relie le package multi-arch au dépôt.
  annotations = [
    "index:org.opencontainers.image.source=${SOURCE_URL}",
    "index:org.opencontainers.image.revision=${REVISION}",
  ]
  output = ["type=registry"]
}
