#!/bin/bash

# Script de instalación automatizada de Argo Rollouts con Minikube, Istio y ArgoCD
# Basado en: ARGO_ROLLOUT_LOCAL.md

set -e  # Salir si algún comando falla

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================
# 1. INSTALACIÓN DE MINIKUBE
# ============================================
echo_info "=========================================="
echo_info "Paso 1: Configuración de Minikube"
echo_info "=========================================="

echo_info "Eliminando instalación anterior de Minikube..."
minikube delete || echo_warning "No hay instalación previa de Minikube"

echo_info "Iniciando Minikube con Podman..."
minikube start --driver=podman --container-runtime=containerd --memory=3621 --cpus=2 --addons=metrics-server --addons=ingress

echo_info "Verificando status de Minikube..."
minikube status

# ============================================
# 2. INSTALACIÓN DE ISTIO
# ============================================
echo_info "=========================================="
echo_info "Paso 2: Instalación de Istio"
echo_info "=========================================="

echo_info "Instalando Istio con perfil demo..."
istioctl install --set profile=demo -y

echo_info "Habilitando Istio en el namespace default..."
kubectl label namespace default istio-injection=enabled --overwrite

echo_info "Esperando a que los pods de Istio estén listos..."
kubectl wait --for=condition=ready pod -l app=istiod -n istio-system --timeout=300s
kubectl wait --for=condition=ready pod -l app=istio-ingressgateway -n istio-system --timeout=300s

echo_info "Verificando pods de Istio..."
kubectl get po -n istio-system

# ============================================
# 3. INSTALACIÓN DE ARGO CD
# ============================================
echo_info "=========================================="
echo_info "Paso 3: Instalación de Argo CD"
echo_info "=========================================="

echo_info "Creando namespace argocd..."
kubectl create namespace argocd || echo_warning "El namespace argocd ya existe"

echo_info "Instalando Argo CD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo_info "Esperando a que Argo CD esté disponible..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

echo_info "Configurando Argo CD para usar HTTPS en lugar de SSH..."
kubectl patch configmap argocd-cm -n argocd --type merge -p '{
  "data": {
    "repositories": "- url: https://github.com\n  insecure: true"
  }
}'

echo_info "Reiniciando Argo CD server para aplicar cambios..."
kubectl rollout restart deployment argocd-server -n argocd
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

echo_info "Obteniendo password de Argo CD..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

echo_info "=========================================="
echo_info "Credenciales de Argo CD:"
echo_info "URL: https://localhost:8080"
echo_info "Username: admin"
echo_info "Password: ${ARGOCD_PASSWORD}"
echo_info "=========================================="

echo_warning "Para acceder a Argo CD, ejecuta en otra terminal:"
echo_warning "kubectl port-forward svc/argocd-server -n argocd 8080:443"

# ============================================
# 4. INSTALACIÓN DE ARGO ROLLOUTS
# ============================================
echo_info "=========================================="
echo_info "Paso 4: Instalación de Argo Rollouts"
echo_info "=========================================="

echo_info "Creando namespace argo-rollouts..."
kubectl create namespace argo-rollouts || echo_warning "El namespace argo-rollouts ya existe"

echo_info "Instalando Argo Rollouts..."
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

echo_info "Esperando a que Argo Rollouts esté disponible..."
kubectl wait --for=condition=available --timeout=300s deployment/argo-rollouts -n argo-rollouts

echo_warning "Para acceder al dashboard de Argo Rollouts, ejecuta:"
echo_warning "kubectl argo rollouts dashboard"

# ============================================
# 5. INSTALACIÓN DE LA APLICACIÓN
# ============================================
echo_info "=========================================="
echo_info "Paso 5: Instalación de la aplicación"
echo_info "=========================================="

MANIFESTS_DIR="./k8s"

if [ ! -d "$MANIFESTS_DIR" ]; then
    echo_error "No se encontró el directorio $MANIFESTS_DIR"
    echo_warning "Saltando instalación de manifiestos de aplicación"
else
    echo_info "Aplicando manifiestos de la aplicación..."
    
    if [ -f "$MANIFESTS_DIR/gateway.yaml" ]; then
        kubectl apply -f $MANIFESTS_DIR/gateway.yaml
    else
        echo_warning "No se encontró gateway.yaml"
    fi
    
    if [ -f "$MANIFESTS_DIR/services.yaml" ]; then
        kubectl apply -f $MANIFESTS_DIR/services.yaml
    else
        echo_warning "No se encontró services.yaml"
    fi
    
    if [ -f "$MANIFESTS_DIR/virtualsvc.yaml" ]; then
        kubectl apply -f $MANIFESTS_DIR/virtualsvc.yaml
    else
        echo_warning "No se encontró virtualsvc.yaml"
    fi
    
    if [ -f "$MANIFESTS_DIR/rollout.yaml" ]; then
        kubectl apply -f $MANIFESTS_DIR/rollout.yaml
    else
        echo_warning "No se encontró rollout.yaml"
    fi

    if [ -f "$MANIFESTS_DIR/secret.yaml" ]; then
        kubectl apply -f $MANIFESTS_DIR/secret.yaml
    else
        echo_warning "No se encontró rollout.yaml"
    fi
    
    if [ -f "$MANIFESTS_DIR/rollouts-demo-argocd.yaml" ]; then
        echo_info "Registrando aplicación en ArgoCD..."
        kubectl apply -f $MANIFESTS_DIR/rollouts-demo-argocd.yaml
    else
        echo_warning "No se encontró rollouts-demo-argocd.yaml"
    fi
fi

# ============================================
# RESUMEN FINAL
# ============================================
echo_info "=========================================="
echo_info "INSTALACIÓN COMPLETADA"
echo_info "=========================================="
echo ""
echo_info "Servicios instalados:"
echo_info "✓ Minikube"
echo_info "✓ Istio"
echo_info "✓ Argo CD (configurado para HTTPS)"
echo_info "✓ Argo Rollouts"
echo ""
echo_info "Para acceder a los dashboards:"
echo ""
echo_info "1. (En otra terminal)Argo CD:"
echo_info "   kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo_info "   URL: https://localhost:8080"
echo_info "   Username: admin"
echo_info "   Password: ${ARGOCD_PASSWORD}"
echo ""
echo_info "2. (En otra terminal)Argo Rollouts:"
echo_info "   kubectl argo rollouts dashboard"
echo ""
echo_info "3. Verificar estado de pods:"
echo_info "   kubectl get pods --all-namespaces"
echo ""
echo_info "4. Abrir tunel para acceder a la aplicación:"
echo_info "   minikube service istio-ingressgateway -n istio-system"
echo_info "   URL: http://rollouts-demo.local:[puerto-http]"
echo ""
echo_info "=========================================="