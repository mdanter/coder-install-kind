#!/bin/bash
set -euo pipefail

# =============================================================================
# Coder on Kind - Local Development Setup
# =============================================================================
#
# PURPOSE:
#   Quickly deploy a fully functional Coder instance on a local Kind cluster
#   for development, testing, and template authoring.
#
# WHAT THIS SOLVES:
#   - No cloud costs for testing
#   - No complex ingress/TLS configuration  
#   - Working DERP relay for workspace connectivity
#   - Wildcard subdomain apps via nip.io
#
# FEATURES:
#   ✓ Web terminal
#   ✓ VS Code Web (code-server)  
#   ✓ coder ssh / coder ping
#   ✓ Wildcard subdomain apps
#   ✓ VS Code Remote SSH (via coder config-ssh)
#   ✗ VS Code Desktop deeplinks (requires HTTPS)
#
# PREREQUISITES:
#   kind, kubectl, helm, docker, jq, curl, coder CLI
#
# USAGE:
#   ./coder-kind.sh install      # Deploy Coder
#   ./coder-kind.sh cleanup      # Remove everything
#   ./coder-kind.sh diagnostics  # Check status
#
# =============================================================================

KIND_CLUSTER_NAME="coder-test"
CODER_NAMESPACE="coder"
TUNNEL_CONTAINER="coder-tunnel"
CODER_URL="http://coder.127.0.0.1.nip.io"

CODER_ADMIN_EMAIL="${CODER_ADMIN_EMAIL:-admin@coder.local}"
CODER_ADMIN_USERNAME="${CODER_ADMIN_USERNAME:-admin}"
CODER_ADMIN_PASSWORD="${CODER_ADMIN_PASSWORD:-SuperSecretPassword123!}"

# Determine config directory based on OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    CODER_CONFIG_DIR="$HOME/Library/Application Support/coderv2"
else
    CODER_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/coderv2"
fi

log() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; exit 1; }

check_prerequisites() {
    log "Checking prerequisites..."
    local missing=()
    for cmd in kind kubectl helm docker jq curl coder; do
        command -v $cmd &>/dev/null || missing+=($cmd)
    done
    [[ ${#missing[@]} -gt 0 ]] && error "Missing required tools: ${missing[*]}"
    log "All prerequisites met"
}

create_kind_cluster() {
    log "Creating Kind cluster..."
    kind delete cluster --name "$KIND_CLUSTER_NAME" 2>/dev/null || true
    kind create cluster --name "$KIND_CLUSTER_NAME"
    log "Kind cluster ready"
}

install_postgresql() {
    log "Installing PostgreSQL..."
    kubectl create namespace "$CODER_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    helm repo update bitnami

    helm upgrade --install postgresql bitnami/postgresql \
        --namespace "$CODER_NAMESPACE" \
        --set auth.username=coder \
        --set auth.password=coder \
        --set auth.database=coder \
        --set primary.persistence.size=1Gi \
        --set primary.resources.requests.memory=64Mi \
        --set primary.resources.requests.cpu=50m \
        --set primary.resources.limits.memory=256Mi \
        --wait --timeout=300s

    kubectl create secret generic coder-db-url \
        --namespace "$CODER_NAMESPACE" \
        --from-literal=url="postgres://coder:coder@postgresql.$CODER_NAMESPACE.svc.cluster.local:5432/coder?sslmode=disable" \
        --dry-run=client -o yaml | kubectl apply -f -

    log "PostgreSQL ready"
}

install_coder() {
    log "Installing Coder..."
    
    helm repo add coder-v2 https://helm.coder.com/v2 2>/dev/null || true
    helm repo update coder-v2

    cat <<EOF | helm upgrade --install coder coder-v2/coder \
        --namespace "$CODER_NAMESPACE" \
        --values - \
        --wait --timeout=600s
coder:
  env:
    - name: CODER_PG_CONNECTION_URL
      valueFrom:
        secretKeyRef:
          name: coder-db-url
          key: url
    - name: CODER_ACCESS_URL
      value: "$CODER_URL"
    - name: CODER_WILDCARD_ACCESS_URL
      value: "*.coder.127.0.0.1.nip.io"
    - name: CODER_OAUTH2_GITHUB_DEFAULT_PROVIDER_ENABLE
      value: "false"
  service:
    type: NodePort
EOF

    log "Coder installed"
}

configure_coredns() {
    log "Configuring CoreDNS for in-cluster DNS resolution..."
    
    local coder_service_ip
    coder_service_ip=$(kubectl get svc coder -n "$CODER_NAMESPACE" -o jsonpath='{.spec.clusterIP}')
    
    [[ -z "$coder_service_ip" ]] && error "Could not get Coder service IP"
    
    # Create a CoreDNS custom config to resolve nip.io domains to Coder service
    # This is needed because workspace pods need to reach coder.127.0.0.1.nip.io
    # but 127.0.0.1 inside a pod refers to the pod itself, not the host
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  nip.io.override: |
    rewrite name regex (.*)\.127\.0\.0\.1\.nip\.io coder.${CODER_NAMESPACE}.svc.cluster.local
EOF

    # Patch CoreDNS to import custom config
    kubectl get configmap coredns -n kube-system -o json | \
    jq '.data.Corefile |= if contains("import /etc/coredns/custom/*.override") then . else gsub("ready"; "ready\n        import /etc/coredns/custom/*.override") end' | \
    kubectl apply -f -

    # Patch CoreDNS deployment to mount the custom configmap
    kubectl patch deployment coredns -n kube-system --type=json -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/volumes/-",
        "value": {
          "name": "coredns-custom",
          "configMap": {
            "name": "coredns-custom"
          }
        }
      },
      {
        "op": "add", 
        "path": "/spec/template/spec/containers/0/volumeMounts/-",
        "value": {
          "name": "coredns-custom",
          "mountPath": "/etc/coredns/custom",
          "readOnly": true
        }
      }
    ]' 2>/dev/null || true

    # Restart CoreDNS to pick up changes
    kubectl rollout restart deployment coredns -n kube-system
    kubectl rollout status deployment coredns -n kube-system --timeout=60s
    
    log "CoreDNS configured: *.127.0.0.1.nip.io -> coder.$CODER_NAMESPACE.svc.cluster.local"
}

start_tunnel() {
    log "Starting tunnel..."
    docker rm -f "$TUNNEL_CONTAINER" 2>/dev/null || true
    
    local kind_ip node_port
    kind_ip=$(docker inspect "${KIND_CLUSTER_NAME}-control-plane" --format '{{.NetworkSettings.Networks.kind.IPAddress}}')
    node_port=$(kubectl get svc coder -n "$CODER_NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')
    
    [[ -z "$kind_ip" ]] && error "Could not get Kind node IP"
    [[ -z "$node_port" ]] && error "Could not get Coder NodePort"
    
    docker run -d \
        --name "$TUNNEL_CONTAINER" \
        --network kind \
        --restart unless-stopped \
        -p 80:80 \
        alpine/socat \
        tcp-listen:80,fork,reuseaddr tcp-connect:${kind_ip}:${node_port}
    
    log "Tunnel ready: localhost:80 -> ${kind_ip}:${node_port}"
}

setup_coder() {
    log "Waiting for Coder API..."
    local attempts=0
    while ! curl -s --max-time 2 "$CODER_URL/api/v2/buildinfo" >/dev/null 2>&1; do
        ((attempts++)) || true
        [[ $attempts -gt 60 ]] && error "Coder not responding at $CODER_URL"
        sleep 2
    done
    
    log "Creating admin user..."
    local create_response
    create_response=$(curl -s --max-time 10 -X POST "$CODER_URL/api/v2/users/first" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$CODER_ADMIN_EMAIL\",\"username\":\"$CODER_ADMIN_USERNAME\",\"password\":\"$CODER_ADMIN_PASSWORD\",\"trial\":false}")
    # Ignore errors - user may already exist
    
    log "Logging in..."
    local login_response token
    login_response=$(curl -s --max-time 10 -X POST "$CODER_URL/api/v2/users/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$CODER_ADMIN_EMAIL\",\"password\":\"$CODER_ADMIN_PASSWORD\"}")
    
    token=$(echo "$login_response" | jq -r '.session_token // empty')
    
    [[ -z "$token" ]] && error "Failed to get session token. Response: $login_response"
    
    rm -rf "$CODER_CONFIG_DIR"
    mkdir -p "$CODER_CONFIG_DIR"
    printf '%s' "$token" > "$CODER_CONFIG_DIR/session"
    printf '%s' "$CODER_URL" > "$CODER_CONFIG_DIR/url"
    
    log "Verifying session..."
    # Use env vars for verification to avoid any file reading timing issues
    if ! CODER_URL="$CODER_URL" CODER_SESSION_TOKEN="$token" coder whoami &>/dev/null; then
        error "Session verification failed. Token may be invalid."
    fi
    
    log "Logged in as $CODER_ADMIN_USERNAME"
}

create_and_push_template() {
    log "Creating template..."
    local template_dir="/tmp/coder-k8s-template"
    rm -rf "$template_dir"
    mkdir -p "$template_dir"

    cat <<'EOF' > "$template_dir/main.tf"
terraform {
  required_providers {
    coder      = { source = "coder/coder" }
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}

provider "coder" {}
provider "kubernetes" {}

variable "namespace" {
  type    = string
  default = "coder"
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  startup_script = <<-EOT
    #!/bin/bash
    set -e
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server
    /tmp/code-server/bin/code-server --auth none --port 13337 >/tmp/code-server.log 2>&1 &
  EOT
}

resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "VS Code Web"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337?folder=/home/coder"
  subdomain    = true
  share        = "owner"
  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 5
    threshold = 10
  }
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = var.namespace
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = { storage = "2Gi" }
    }
  }
}

resource "kubernetes_deployment_v1" "main" {
  count            = data.coder_workspace.me.start_count
  wait_for_rollout = false
  metadata {
    name      = "coder-${data.coder_workspace.me.id}"
    namespace = var.namespace
  }
  spec {
    replicas = 1
    selector {
      match_labels = { "app.kubernetes.io/instance" = "coder-${data.coder_workspace.me.id}" }
    }
    template {
      metadata {
        labels = { "app.kubernetes.io/instance" = "coder-${data.coder_workspace.me.id}" }
      }
      spec {
        security_context {
          run_as_user = 1000
          fs_group    = 1000
        }
        container {
          name    = "dev"
          image   = "codercom/enterprise-base:ubuntu"
          command = ["sh", "-c", coder_agent.main.init_script]
          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }
          volume_mount {
            mount_path = "/home/coder"
            name       = "home"
          }
        }
        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
          }
        }
      }
    }
  }
}
EOF

    log "Pushing template..."
    CODER_URL="$CODER_URL" CODER_SESSION_TOKEN="$(cat "$CODER_CONFIG_DIR/session")" \
        coder templates push kubernetes -d "$template_dir" -y --variable namespace=coder
    log "Template ready"
}

print_status() {
    echo ""
    echo "========================================"
    echo "  Coder is ready!"
    echo "========================================"
    echo ""
    echo "  URL:      $CODER_URL"
    echo "  Username: $CODER_ADMIN_USERNAME"
    echo "  Password: $CODER_ADMIN_PASSWORD"
    echo ""
    echo "  Create a workspace:"
    echo "    coder create my-workspace --template kubernetes"
    echo ""
    echo "  Connect:"
    echo "    coder ssh my-workspace"
    echo "    coder ping my-workspace"
    echo ""
}

run_diagnostics() {
    echo "=== Tunnel ==="
    docker ps --filter name=$TUNNEL_CONTAINER --format "table {{.Status}}\t{{.Ports}}" 2>/dev/null || echo "Not running"
    echo ""
    
    echo "=== Coder Pod ==="
    kubectl get pods -n $CODER_NAMESPACE -l app.kubernetes.io/name=coder -o wide 2>/dev/null || echo "Not found"
    echo ""
    
    echo "=== CoreDNS ==="
    kubectl get configmap coredns-custom -n kube-system -o jsonpath='{.data}' 2>/dev/null | jq -r '."nip.io.override" // "Not configured"' || echo "Not configured"
    echo ""
    
    echo "=== DNS Test (from a pod) ==="
    kubectl run -it --rm dns-test --image=busybox --restart=Never -- nslookup coder.127.0.0.1.nip.io 2>/dev/null || echo "Could not run DNS test"
    echo ""
    
    echo "=== Health ==="
    curl -s --max-time 5 "$CODER_URL/api/v2/debug/health" 2>/dev/null | \
        jq '{healthy, derp: .derp.healthy, websocket: .websocket.healthy}' 2>/dev/null || echo "Cannot reach $CODER_URL"
    echo ""
    
    echo "=== Logs (last 10 lines) ==="
    kubectl logs -n $CODER_NAMESPACE -l app.kubernetes.io/name=coder --tail=10 2>/dev/null || echo "No logs"
}

cleanup() {
    log "Cleaning up..."
    docker rm -f "$TUNNEL_CONTAINER" 2>/dev/null || true
    kind delete cluster --name "$KIND_CLUSTER_NAME" 2>/dev/null || true
    rm -rf "$CODER_CONFIG_DIR" /tmp/coder-k8s-template
    log "Done"
}

main() {
    case "${1:-install}" in
        install)
            check_prerequisites
            create_kind_cluster
            install_postgresql
            install_coder
            configure_coredns
            start_tunnel
            setup_coder
            create_and_push_template
            print_status
            ;;
        cleanup)
            cleanup
            ;;
        diagnostics|diag)
            run_diagnostics
            ;;
        tunnel)
            start_tunnel
            ;;
        *)
            echo "Usage: $0 {install|cleanup|diagnostics|tunnel}"
            exit 1
            ;;
    esac
}

main "$@"

