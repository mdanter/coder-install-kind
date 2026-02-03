# Getting Started: Coder v2 on kind (Kubernetes IN Docker)

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Docker | Running & configured | [docker.com](https://docs.docker.com/get-docker/) |
| kind | v0.17+ | `go install sigs.k8s.io/kind@latest` or `brew install kind` |
| kubectl | 1.19+ | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| Helm | 3.5+ | `brew install helm` or [helm.sh](https://helm.sh/docs/intro/install/) |

---

## Step 1: Create a kind Cluster

**Basic cluster:**
```bash
kind create cluster --name coder
kubectl cluster-info --context kind-coder
```

**With port mappings** (recommended for easier access):

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8080
        protocol: TCP
```

```bash
kind create cluster --name coder --config kind-config.yaml
```

---

## Step 2: Create the Coder Namespace

```bash
kubectl create namespace coder
```

---

## Step 3: Deploy PostgreSQL (In-Cluster)

From the [official Coder docs](https://github.com/coder/coder/blob/main/docs/install/kubernetes.md):

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install postgresql bitnami/postgresql \
    --namespace coder \
    --set auth.username=coder \
    --set auth.password=coder \
    --set auth.database=coder \
    --set primary.persistence.size=10Gi
```

Wait for PostgreSQL to be ready:
```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql -n coder --timeout=120s
```

---

## Step 4: Create the Database Secret

```bash
kubectl create secret generic coder-db-url -n coder \
  --from-literal=url="postgres://coder:coder@postgresql.coder.svc.cluster.local:5432/coder?sslmode=disable"
```

---

## Step 5: Configure Coder with values.yaml

Create a `values.yaml`:

```yaml
coder:
  env:
    - name: CODER_PG_CONNECTION_URL
      valueFrom:
        secretKeyRef:
          name: coder-db-url
          key: url
    # Set access URL for workspaces to connect back
    - name: CODER_ACCESS_URL
      value: "http://localhost:8080"
    # Disable default GitHub OAuth for local testing
    - name: CODER_OAUTH2_GITHUB_DEFAULT_PROVIDER_ENABLE
      value: "false"

  service:
    # Use NodePort for kind
    type: NodePort
    httpNodePort: "30080"
```

---

## Step 6: Install Coder via Helm

```bash
helm repo add coder-v2 https://helm.coder.com/v2
helm install coder coder-v2/coder \
    --namespace coder \
    --values values.yaml
```

Watch Coder start:
```bash
kubectl get pods -n coder -w
```

---

## Step 7: Access Coder

**Option A: Port-forward (simplest, works without kind config)**
```bash
kubectl port-forward svc/coder -n coder 8080:80
```
Then visit: http://localhost:8080

**Option B: If you used `extraPortMappings` with `httpNodePort: "30080"`**

Visit http://localhost:8080 directly.

---

## Step 8: Create Your First Admin User

1. Open http://localhost:8080
2. Create your admin account
3. Log in

---

## Step 9: Add a Kubernetes Template

**Option A: Via the UI**
1. Go to **Templates** → **Create Template** → **Choose a starter template**
2. Select **Kubernetes**
3. Set `use_kubeconfig` = `false` (since Coder runs inside the cluster)
4. Set `namespace` = `coder`

**Option B: Via CLI**
```bash
# Initialize a kubernetes template in a local directory
coder templates init --id kubernetes

# You'll be prompted for variables when pushing
cd kubernetes
coder templates push
```

When prompted:
- `use_kubeconfig`: **false** (Coder is running as a pod in the same cluster)
- `namespace`: **coder** (or another namespace that exists)

---

# Common Gotchas & Troubleshooting

## 1. **"Access URL" Issues / Workspaces Can't Connect**

**Symptom:** Workspaces start but the agent can't reach the Coder server.

**Cause:** `CODER_ACCESS_URL` is not set or incorrect.

**Fix:** Ensure `CODER_ACCESS_URL` is set in your values.yaml:
```yaml
- name: CODER_ACCESS_URL
  value: "http://localhost:8080"
```

Then upgrade:
```bash
helm upgrade coder coder-v2/coder -n coder -f values.yaml
```

---

## 2. **PostgreSQL Connection Refused**

**Symptom:** Coder pod in `CrashLoopBackOff` with DB connection errors.

**Debug:**
```bash
kubectl logs -l app.kubernetes.io/name=coder -n coder
kubectl get pods -n coder
```

**Causes & Fixes:**
- PostgreSQL not ready yet → wait and retry
- Verify the secret URL:
```bash
kubectl get secret coder-db-url -n coder -o jsonpath='{.data.url}' | base64 -d
```

---

## 3. **Workspace Pods Stuck in Pending**

**Symptom:** Workspaces never start, pods stay `Pending`.

**Debug:**
```bash
kubectl describe pod <workspace-pod-name> -n coder
kubectl get events -n coder --sort-by='.lastTimestamp'
```

**Common causes:**
- **Insufficient resources:** kind nodes have limited CPU/memory. Reduce workspace resource requests in your template.
- **PVC not bound:** Check PVC status:
```bash
kubectl get pvc -n coder
```

---

## 4. **Envbuilder/Devcontainer Errors: "failed to delete file"**

**Symptom:** When using `kubernetes-devcontainer` template, builds fail with file deletion errors.

**Fix:** This is a known kind-specific issue. Add ignore paths to your template:

```hcl
# In the envbuilder environment block
"ENVBUILDER_IGNORE_PATHS": "/product_name,/product_uuid,/var/run"
```

(This is documented in the [kubernetes-devcontainer template](https://github.com/coder/coder/blob/main/examples/templates/kubernetes-devcontainer/main.tf))

---

## 5. **Service Account / RBAC Permission Denied**

**Symptom:** `Error: pods is forbidden: User "system:serviceaccount:coder:coder"...`

**Cause:** Coder's service account doesn't have permissions to create workspace pods.

**Fix:** The helm chart sets `serviceAccount.workspacePerms: true` by default. If you disabled it, re-enable:

```yaml
coder:
  serviceAccount:
    workspacePerms: true
    enableDeployments: true
```

Then upgrade:
```bash
helm upgrade coder coder-v2/coder -n coder -f values.yaml
```

---

## 6. **kind Node Runs Out of Disk**

**Symptom:** Pods evicted, containers failing to start with disk pressure.

**Check:**
```bash
docker exec -it coder-control-plane df -h
```

**Fix:**
```bash
# Prune Docker resources
docker system prune -a --volumes

# Or delete and recreate cluster
kind delete cluster --name coder
kind create cluster --name coder
```

---

## 7. **Image Pull Errors**

**Symptom:** `ErrImagePull` or `ImagePullBackOff`

**Fix for images not on public registries:** Load images into kind:
```bash
docker pull your-image:tag
kind load docker-image your-image:tag --name coder
```

---

## 8. **Slow Workspace Startup**

**Cause:** kind pulls images from the network each time a workspace starts.

**Fix:** Pre-load common workspace images:
```bash
kind load docker-image codercom/enterprise-base:ubuntu --name coder
```

---

## 9. **DNS Resolution Failures from Workspaces**

**Symptom:** Workspace can't resolve external hostnames.

**Debug:**
```bash
kubectl run -it --rm debug --image=busybox -n coder -- nslookup google.com
```

**Fix:** Usually a Docker networking issue. Restart Docker Desktop or recreate the kind cluster.

---

## 10. **Helm Upgrade Fails with "field is immutable"**

**Symptom:** Changing service type fails with immutable field error.

**Fix:** For service type changes, uninstall and reinstall:
```bash
helm uninstall coder -n coder
helm install coder coder-v2/coder -n coder -f values.yaml
```

---

## Useful Debug Commands

```bash
# All resources in coder namespace
kubectl get all -n coder

# Coder server logs
kubectl logs -l app.kubernetes.io/name=coder -n coder -f

# PostgreSQL logs
kubectl logs -l app.kubernetes.io/name=postgresql -n coder

# Describe a failing pod
kubectl describe pod <pod-name> -n coder

# Events sorted by time
kubectl get events -n coder --sort-by='.lastTimestamp'

# Shell into Coder pod
kubectl exec -it deploy/coder -n coder -- /bin/sh
```

---

## Quick Reset

If things go sideways:
```bash
kind delete cluster --name coder
kind create cluster --name coder --config kind-config.yaml
# Re-run steps 2-7
```

---

## Key Differences from Production

| Aspect | kind (local) | Production |
|--------|--------------|------------|
| PostgreSQL | In-cluster Bitnami chart | Managed (RDS, Cloud SQL, etc.) |
| Service type | NodePort | LoadBalancer or Ingress |
| TLS | None | Required |
| `CODER_ACCESS_URL` | `http://localhost:8080` | `https://coder.example.com` |
| Storage | Local path provisioner | Cloud storage class |
