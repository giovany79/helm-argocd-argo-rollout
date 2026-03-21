#!/bin/bash
# Wrapper para helm upgrade que actualiza appVersion en Chart.yaml
# Uso: ./helm-upgrade.sh <tag> [opciones adicionales de helm]
#
# Ejemplos:
#   ./helm-upgrade.sh yellow
#   ./helm-upgrade.sh blue --set replicaCount=3
#
# Según la documentación oficial de Helm, --app-version solo existe en
# "helm package", no en "helm upgrade". Este script actualiza Chart.yaml
# antes del upgrade para mantener appVersion sincronizado con image.tag.
# Ref: https://helm.sh/docs/helm/helm_package/

set -e

CHART_PATH="./helm/rollouts-demo"
RELEASE_NAME="rollouts-demo"
TAG=${1:?'Uso: ./helm-upgrade.sh <tag> [opciones adicionales]'}
shift

# Actualizar appVersion en Chart.yaml
sed -i.bak "s/^appVersion:.*/appVersion: \"$TAG\"/" "$CHART_PATH/Chart.yaml"
rm -f "$CHART_PATH/Chart.yaml.bak"

echo "→ appVersion actualizado a: $TAG"

helm upgrade $RELEASE_NAME $CHART_PATH \
    --set image.tag=$TAG \
    --force-conflicts \
    "$@"
