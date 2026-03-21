#!/bin/bash

# Script de instalación automatizada: Minikube + Istio + Helm + ArgoCD + Argo Rollouts
# Versión 3.0.0 - Incluye Helm como gestor de la aplicación
# Basado en: setup-all-2.0.0.sh y docs/ARGO_ROLLOUT_LOCAL.md

set -e

# ============================================
# CONFIGURACIÓN
# ============================================
MINIKUBE_DRIVER="podman"
MINIKUBE_MEMORY="3621"
MINIKUBE_CPUS="2"
HELM_CHART_PATH="./helm/rollouts-demo"
HELM_RELEASE_NAME="rollouts-demo"
HELM_NAMESPACE="default"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
echo_step()    { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE} $1${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ============================================
# FUNCIONES DE VERIFICACIÓN
# ============================================
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo_error "$1 no está instalado. Por favor instálalo antes de continuar."
        echo_info "Referencia: $2"
        return 1
    fi
    echo_info "✓ $1 encontrado: $(command -v $1)"
}

wait_for_deployment() {
    local name=$1
    local namespace=$2
    local timeout=${3:-300}
    echo_info "Esperando deployment $name en namespace $namespace (timeout: ${timeout}s)..."
    kubectl wait --for=condition=available --timeout=${timeout}s deployment/$name -n $namespace
}

# ============================================
# PASO 0: VERIFICAR PRE-REQUISITOS
# ============================================
echo_step "Paso 0: Verificando pre-requisitos"

MISSING=0
check_command "minikube" "https://minikube.sigs.k8s.io/docs/start/" || MISSING=1
check_command "podman"   "https://podman.io/" || MISSING=1
check_command "istioctl" "https://istio.io/latest/docs/ops/diagnostic-tools/istioctl/" || MISSING=1
check_command "helm"     "https://helm.sh/docs/intro/install/" || MISSING=1
check_command "kubectl"  "https://kubernetes.io/docs/tasks/tools/" || MISSING=1

if [ "$MISSING" -eq 1 ]; then
    echo_error "Faltan herramientas requeridas. Instálalas y vuelve a ejecutar el script."
    exit 1
fi

echo_info "Todas las herramientas están disponibles."

# ============================================
# PASO 1: MINIKUBE
# ============================================
echo_step "Paso 1: Configuración de Minikube"

echo_info "Eliminando instalación anterior de Minikube..."
minikube delete 2>/dev/null || echo_warning "No hay instalación previa"

echo_info "Iniciando Minikube con $MINIKUBE_DRIVER..."
minikube start \
    --driver=$MINIKUBE_DRIVER \
    --container-runtime=containerd \
    --memory=$MINIKUBE_MEMORY \
    --cpus=$MINIKUBE_CPUS \
    --addons=metrics-server \
    --addons=ingress

echo_info "Verificando status..."
minikube status

# ============================================
# PASO 2: ISTIO
# ============================================
echo_step "Paso 2: Instalación de Istio"

echo_info "Instalando Istio con perfil demo..."
istioctl install --set profile=demo -y

echo_info "Habilitando inyección de Istio en namespace default..."
kubectl label namespace default istio-injection=enabled --overwrite

echo_info "Esperando pods de Istio..."
kubectl wait --for=condition=ready pod -l app=istiod -n istio-system --timeout=300s
kubectl wait --for=condition=ready pod -l app=istio-ingressgateway -n istio-system --timeout=300s

echo_info "Pods de Istio:"
kubectl get po -n istio-system

# ============================================
# PASO 3: HELM (verificación y repos)
# ============================================
echo_step "Paso 3: Configuración de Helm"

echo_info "Versión de Helm: $(helm version --short)"

echo_info "Verificando Helm chart local..."
if [ ! -f "$HELM_CHART_PATH/Chart.yaml" ]; then
    echo_error "No se encontró el chart en $HELM_CHART_PATH"
    exit 1
fi

echo_info "Validando chart con helm lint..."
helm lint $HELM_CHART_PATH

echo_info "Template preview (dry-run):"
helm template $HELM_RELEASE_NAME $HELM_CHART_PATH --namespace $HELM_NAMESPACE | head -30
echo_info "... (truncado)"

echo_info "✓ Helm chart validado correctamente"

# ============================================
# PASO 4: ARGO CD
# ============================================
echo_step "Paso 4: Instalación de Argo CD"

echo_info "Creando namespace argocd..."
kubectl create namespace argocd 2>/dev/null || echo_warning "Namespace argocd ya existe"

echo_info "Instalando Argo CD (server-side apply para evitar límite de anotaciones en CRDs)..."
kubectl apply -n argocd --server-side=true --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

wait_for_deployment "argocd-server" "argocd"

echo_info "Configurando ArgoCD para repos HTTPS inseguros..."
kubectl patch configmap argocd-cm -n argocd --type merge -p '{
  "data": {
    "repositories": "- url: https://github.com\n  insecure: true"
  }
}'

echo_info "Reiniciando ArgoCD server..."
kubectl rollout restart deployment argocd-server -n argocd
wait_for_deployment "argocd-server" "argocd"

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

echo_info "Credenciales de Argo CD:"
echo_info "  URL:      https://localhost:8080"
echo_info "  Usuario:  admin"
echo_info "  Password: ${ARGOCD_PASSWORD}"

# ============================================
# PASO 5: ARGO ROLLOUTS
# ============================================
echo_step "Paso 5: Instalación de Argo Rollouts"

echo_info "Creando namespace argo-rollouts..."
kubectl create namespace argo-rollouts 2>/dev/null || echo_warning "Namespace argo-rollouts ya existe"

echo_info "Instalando Argo Rollouts..."
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

wait_for_deployment "argo-rollouts" "argo-rollouts"

echo_info "✓ Argo Rollouts instalado"

# ============================================
# PASO 6: DESPLEGAR APLICACIÓN CON HELM
# ============================================
echo_step "Paso 6: Desplegando aplicación con Helm"

# Primero aplicar el secret de ArgoCD (fuera del chart para evitar conflictos de namespace)
echo_info "Aplicando secret del repositorio en ArgoCD..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-github-giovany79
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/giovany79/argo-rollout.git
  insecure: "true"
EOF

echo_info "Instalando chart con Helm (rollout, services, gateway, virtualservice)..."
helm upgrade --install $HELM_RELEASE_NAME $HELM_CHART_PATH \
    --namespace $HELM_NAMESPACE \
    --force-conflicts \
    --wait \
    --timeout 120s

echo_info "Release de Helm:"
helm list -n $HELM_NAMESPACE

echo_info "Registrando aplicación en ArgoCD..."
kubectl apply -f - <<APPEOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rollouts-demo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/giovany79/argo-rollout.git
    targetRevision: main
    path: helm/rollouts-demo
    helm:
      valueFiles:
      - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
APPEOF

echo_info "Verificando recursos desplegados..."
kubectl get rollout -n $HELM_NAMESPACE 2>/dev/null || echo_warning "CRD de Rollout aún no disponible"
kubectl get svc -n $HELM_NAMESPACE
kubectl get gateway -n $HELM_NAMESPACE 2>/dev/null || true
kubectl get virtualservice -n $HELM_NAMESPACE 2>/dev/null || true

# ============================================
# RESUMEN FINAL
# ============================================
echo_step "INSTALACIÓN COMPLETADA"

echo ""
echo_info "Componentes instalados:"
echo_info "  ✓ Minikube ($MINIKUBE_DRIVER, ${MINIKUBE_MEMORY}MB, ${MINIKUBE_CPUS} CPUs)"
echo_info "  ✓ Istio (perfil demo)"
echo_info "  ✓ Helm (chart: $HELM_CHART_PATH)"
echo_info "  ✓ Argo CD"
echo_info "  ✓ Argo Rollouts"
echo_info "  ✓ Aplicación rollouts-demo (via Helm)"
echo ""
echo_info "Para acceder a los dashboards (cada uno en una terminal aparte):"
echo ""
echo_info "  1. Argo CD:"
echo_info "     kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo_info "     URL: https://localhost:8080"
echo_info "     Usuario: admin | Password: ${ARGOCD_PASSWORD}"
echo ""
echo_info "  2. Argo Rollouts Dashboard:"
echo_info "     kubectl argo rollouts dashboard"
echo_info "     URL: http://localhost:3100"
echo ""
echo_info "  3. Aplicación (via Istio Ingress):"
echo_info "     minikube service istio-ingressgateway -n istio-system"
echo_info "     Host: rollouts-demo.local"
echo ""
echo_info "Comandos útiles:"
echo_info "  helm list                                    # Ver releases de Helm"
echo_info "  helm upgrade rollouts-demo $HELM_CHART_PATH --force-conflicts  # Actualizar la app"
echo_info "  helm rollback rollouts-demo 1                # Rollback a versión anterior"
echo_info "  kubectl argo rollouts get rollout rollouts-demo  # Estado del rollout"
echo_info "  kubectl get pods                             # Ver pods"
echo ""
echo_info "Para probar un canary deployment, cambia el tag de imagen:"
echo_info "  helm upgrade rollouts-demo $HELM_CHART_PATH --set image.tag=yellow --force-conflicts"
echo_info "  kubectl argo rollouts get rollout rollouts-demo -w"
echo ""

# ============================================
# PASO 7: ABRIR APLICACIÓN EN EL NAVEGADOR
# ============================================
echo_step "Paso 7: Abriendo aplicación en el navegador"
echo_info "Abriendo túnel de Minikube al Istio Ingress Gateway..."
echo_info "Usá el puerto HTTP (80) de la tabla que aparece abajo."
echo_info "Presioná Ctrl+C para cerrar el túnel cuando termines."
echo ""
minikube service istio-ingressgateway -n istio-system
