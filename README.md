# Argo Rollouts Demo - Local Setup con Helm, ArgoCD e Istio

Entorno local completo para practicar **Canary Deployments** usando Argo Rollouts con traffic management de Istio, gestionado por Helm y sincronizado con ArgoCD.

## Arquitectura

```
Minikube (Podman + containerd)
├── Istio (service mesh + ingress gateway)
├── Argo CD (GitOps - sincroniza el repo con el cluster)
├── Argo Rollouts (canary deployments progresivos)
└── rollouts-demo (app demo desplegada con Helm)
```

## Pre-requisitos

Instalar las siguientes herramientas antes de comenzar:

| Herramienta | Instalación |
|-------------|-------------|
| Minikube | https://minikube.sigs.k8s.io/docs/start/?arch=%2Fmacos%2Farm64%2Fstable%2Fbinary+download |
| Podman | https://podman.io/ |
| istioctl | https://istio.io/latest/docs/ops/diagnostic-tools/istioctl/ |
| Helm | https://helm.sh/docs/intro/install/ |
| kubectl | https://kubernetes.io/docs/tasks/tools/ |
| Argo Rollouts CLI | https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation |
| Argo CD CLI (opcional) | https://argo-cd.readthedocs.io/en/stable/cli_installation/ |

### Instalación rápida en macOS

```bash
brew install minikube podman helm kubectl
brew install istioctl
brew install argoproj/tap/kubectl-argo-rollouts
```

## Estructura del proyecto

```
.
├── README.md
├── setup-all-3.0.0.sh          # Script automatizado de instalación
├── setup-all-2.0.0.sh          # Script anterior (sin Helm)
├── helm/
│   └── rollouts-demo/
│       ├── Chart.yaml           # Metadata del chart
│       ├── values.yaml          # Valores configurables
│       └── templates/
│           ├── _helpers.tpl     # Template helpers
│           ├── rollout.yaml     # Argo Rollout (canary)
│           ├── services.yaml    # Services canary + stable
│           ├── gateway.yaml     # Istio Gateway
│           └── virtualservice.yaml  # Istio VirtualService
├── k8s/                         # Manifiestos originales (sin Helm)
└── docs/
    └── ARGO_ROLLOUT_LOCAL.md    # Documentación original paso a paso
```

## Instalación automatizada

La forma más rápida de levantar todo el entorno:

```bash
chmod +x setup-all-3.0.0.sh
./setup-all-3.0.0.sh
```

El script ejecuta los 6 pasos descritos abajo de forma secuencial, validando cada componente antes de continuar.

---

## Instalación paso a paso (manual)

### Paso 1: Iniciar Minikube

```bash
# Eliminar instalación anterior (si existe)
minikube delete

# Iniciar con Podman
minikube start \
    --driver=podman \
    --container-runtime=containerd \
    --memory=3621 \
    --cpus=2 \
    --addons=metrics-server \
    --addons=ingress

# Verificar
minikube status
```

### Paso 2: Instalar Istio

```bash
# Instalar con perfil demo
istioctl install --set profile=demo -y

# Habilitar inyección automática de sidecar en namespace default
kubectl label namespace default istio-injection=enabled --overwrite

# Verificar que los pods estén corriendo
kubectl get po -n istio-system
```

Esperar a que todos los pods en `istio-system` estén en estado `Running`.

### Paso 3: Validar Helm chart

```bash
# Verificar que el chart sea válido
helm lint ./helm/rollouts-demo

# Preview de los manifiestos que se van a generar
helm template rollouts-demo ./helm/rollouts-demo
```

### Paso 4: Instalar Argo CD

```bash
# Crear namespace
kubectl create namespace argocd

# Instalar ArgoCD (server-side apply para evitar error de CRDs muy grandes)
kubectl apply -n argocd --server-side=true --force-conflicts \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Esperar a que esté listo
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Configurar para repos HTTPS
kubectl patch configmap argocd-cm -n argocd --type merge -p '{
  "data": {
    "repositories": "- url: https://github.com\n  insecure: true"
  }
}'

# Reiniciar para aplicar cambios
kubectl rollout restart deployment argocd-server -n argocd
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Obtener password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo
```

### Paso 5: Instalar Argo Rollouts

```bash
# Crear namespace
kubectl create namespace argo-rollouts

# Instalar
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# Esperar a que esté listo
kubectl wait --for=condition=available --timeout=300s deployment/argo-rollouts -n argo-rollouts
```

### Paso 6: Desplegar la aplicación con Helm

```bash
# Aplicar secret del repositorio en ArgoCD
kubectl apply -f k8s/secret.yaml

# Instalar el chart (rollout, services, gateway, virtualservice)
# --force-conflicts es necesario porque Argo Rollouts controller modifica los services
helm upgrade --install rollouts-demo ./helm/rollouts-demo \
    --namespace default \
    --force-conflicts \
    --wait \
    --timeout 120s

# Registrar la aplicación en ArgoCD
kubectl apply -f k8s/rollouts-demo-argocd.yaml

# Verificar
helm list
kubectl get rollout
kubectl get svc
kubectl get pods
```

> **Nota:** El secret y la Application de ArgoCD se aplican con `kubectl apply` por separado porque pertenecen al namespace `argocd`, no al release de Helm en `default`. Mezclarlos en el chart causa conflictos de ownership.

> **Nota:** `--force-conflicts` es necesario porque Argo Rollouts controller toma ownership del campo `.spec.selector` de los services canary y stable. Sin este flag, Helm 4 (que usa server-side apply) rechaza el upgrade por conflicto de field managers.

---

## Acceso a los dashboards

Cada comando se ejecuta en una terminal separada:

### Argo CD

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

- URL: https://localhost:8080
- Usuario: `admin`
- Password: obtenido en el paso 4

### Argo Rollouts Dashboard

```bash
kubectl argo rollouts dashboard
```

- URL: http://localhost:3100

### Aplicación (via Istio Ingress)

```bash
minikube service istio-ingressgateway -n istio-system
```

Usar el puerto HTTP asignado con el host `rollouts-demo.local`.

---

## Probar un Canary Deployment

Una vez todo esté corriendo, puedes simular un canary deployment cambiando la versión de la imagen:

```bash
# Cambiar de green a yellow
helm upgrade rollouts-demo ./helm/rollouts-demo --set image.tag=yellow --force-conflicts

# Observar el progreso del canary
kubectl argo rollouts get rollout rollouts-demo -w
```

El rollout seguirá los pasos definidos en `values.yaml`:
1. 5% del tráfico al canary → pausa manual
2. 20% → espera 10s
3. 40% → espera 10s
4. 60% → espera 10s
5. 80% → espera 10s
6. 100% → promoción completa

### Promover manualmente el canary (después de la primera pausa)

```bash
kubectl argo rollouts promote rollouts-demo
```

### Abortar un rollout

```bash
kubectl argo rollouts abort rollouts-demo
```

### Rollback con Helm

```bash
# Ver historial de releases
helm history rollouts-demo

# Volver a la versión anterior
helm rollback rollouts-demo 1 --force-conflicts
```

---

## Personalización del Helm chart

Los valores configurables están en `helm/rollouts-demo/values.yaml`:

| Parámetro | Default | Descripción |
|-----------|---------|-------------|
| `replicaCount` | `1` | Número de réplicas |
| `image.repository` | `argoproj/rollouts-demo` | Imagen del contenedor |
| `image.tag` | `green` | Tag de la imagen (`green`, `yellow`, `blue`, `red`, `orange`, `purple`) |
| `containerPort` | `8080` | Puerto del contenedor |
| `resources.requests.memory` | `32Mi` | Memoria solicitada |
| `resources.requests.cpu` | `5m` | CPU solicitado |
| `canary.steps` | ver values.yaml | Pasos del canary deployment |
| `gateway.hosts` | `["*"]` | Hosts del Istio Gateway |
| `virtualService.hosts` | `["*"]` | Hosts del VirtualService |
| `argocd.repoURL` | repo de GitHub | URL del repositorio para ArgoCD |
| `argocd.targetRevision` | `main` | Branch/tag del repo |
| `argocd.path` | `helm/rollouts-demo` | Path del chart en el repo |

Ejemplo de override:

```bash
helm upgrade rollouts-demo ./helm/rollouts-demo \
    --set image.tag=blue \
    --set replicaCount=3 \
    --force-conflicts
```

---

## Troubleshooting

### Error: conflict with "rollouts-controller" o "before-first-apply" en helm upgrade

Si al hacer `helm upgrade` ves un error como:

```
conflict with "rollouts-controller" using v1: .spec.selector
conflict with "before-first-apply" using v1: .spec.selector
```

Helm 4 usa server-side apply por defecto. Argo Rollouts controller y Kubernetes toman ownership de `.spec.selector` en los services. Agregar `--force-conflicts` a todos los `helm upgrade`:

```bash
helm upgrade rollouts-demo ./helm/rollouts-demo --set image.tag=yellow --force-conflicts
```

### Error: "metadata.annotations: Too long" al instalar ArgoCD

El CRD de `applicationsets.argoproj.io` excede el límite de 262KB de anotaciones con `kubectl apply` estándar. Usar server-side apply:

```bash
kubectl apply -n argocd --server-side=true --force-conflicts \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

---

## Comandos útiles

```bash
# Estado general
kubectl get pods
kubectl get rollout
kubectl get svc

# Argo Rollouts
kubectl argo rollouts get rollout rollouts-demo
kubectl argo rollouts status rollouts-demo

# Helm (siempre usar --force-conflicts en upgrade/rollback)
helm list
helm status rollouts-demo
helm history rollouts-demo
helm upgrade rollouts-demo ./helm/rollouts-demo --force-conflicts
helm rollback rollouts-demo 1 --force-conflicts

# Logs
kubectl logs -l app=rollouts-demo -f

# Limpiar todo
minikube delete
```

---

## Versiones del documento

| Fecha | Descripción | Realizó |
|-------|-------------|---------|
| 2026/02/12 | Creación de documentación original y script v2.0.0 | @Giovany Villegas Gomez, @German Ramirez Gaviria |
| 2026/03/21 | Script v3.0.0 con Helm chart y README | @Giovany Villegas Gomez |
