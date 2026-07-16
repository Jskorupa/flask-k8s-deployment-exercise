# hello-world-app - containerized Flask app + Kubernetes manifests

## Layout

```
Dockerfile
requirements.txt
.dockerignore
app.py
k8s/
  base/                     # generic, reusable across every similar app
    serviceaccount.yaml
    deployment.yaml
    service.yaml
    hpa.yaml
    pdb.yaml
    kustomization.yaml
  overlays/
    production/             # THIS app's specialization of the base
      namespace.yaml
      ingress.yaml
      resource-governance.yaml
      kustomization.yaml
```

## Part 1 - Dockerfile

* Multi-stage build (`builder` installs deps into a `--user` prefix, runtime
  image only copies the installed packages + `app.py`) - small final image,
  no compilers/build tooling shipped to production.
* Runs as a non-root, unprivileged user.
* Serves via **gunicorn**, not `app.run()` / the Flask dev server - the dev
  server is single-threaded, unsuited for production, and logs a warning
  telling you exactly that.
* Listens on `8080` inside the container. This is `EXPOSE`, not a host
  bind - it doesn't reserve anything on the node.
* Includes a `HEALTHCHECK` for parity outside Kubernetes too.

Build/run locally:
```bash
docker build -t hello-world-app:1.0.1 .
docker run --rm -p 8080:8080 hello-world-app:1.0.1
```

## Part 2 - Kubernetes manifests

Uses **Kustomize** with a `base/` + `overlays/<app>/` split rather than one
flat set of YAML, specifically because of the "20 more similar apps"
requirement (see below).

### High availability
* `replicas: 3` baseline, `RollingUpdate` with `maxUnavailable: 0` so a
  deploy never drops serving capacity.
* `topologySpreadConstraints` (hard on `hostname`, soft on `zone`) +
  `podAntiAffinity` pods spread across nodes/AZs so one node or zone
  failure doesn't take the app down.
* `PodDisruptionBudget` (`minAvailable: 2`) protects the app during node
  drains / cluster upgrades / autoscaler scale-downs.
* Liveness, readiness, and startup probes - startup probe gives slow
  cold-starts room without weakening the liveness probe's sensitivity.

### Scalability
* `HorizontalPodAutoscaler` on CPU (70%) and memory (75%) utilization,
  `minReplicas: 3` / `maxReplicas: 10`, with `behavior` tuned to scale up
  fast and scale down cautiously (5 min stabilization) to avoid flapping.
* Requests/limits set small (`50m/64Mi` request, `250m/128Mi` limit) to
  match this trivial app's actual footprint.

### Not pinned to a host port
* Container only declares a `containerPort` (`8080`); no `hostPort`.
* `Service` is `ClusterIP`; external traffic is routed via `Ingress` on the
  cluster's existing ingress controller — never `NodePort`/`hostNetwork`.

## Part 3 - dummy URL
`Ingress` routes `https://hello-world.apps.example.com/` to the service.

### Reproducibility & cost efficiency for ~20 more similar apps

1. **`k8s/base/` is app-agnostic** - no namespace, hostname, or app name
   baked in, just the shape every similar app shares.
2. **Onboarding app #21 = copy `overlays/production/`, edit ~5 lines**
   (namespace, namePrefix, image tag, Ingress host, ResourceQuota).
3. **Cost efficiency comes from what's shared at the cluster level:**
   * One ingress controller for all apps, not one LoadBalancer per app
     the biggest per app cloud cost avoided entirely.
   * HPA with low `minReplicas` and tight requests avoids reserving idle
     capacity, letting the cluster autoscaler bin-pack many small apps.
   * `ResourceQuota`/`LimitRange` per namespace keeps capacity planning
     predictable as more apps are added.
   * Kustomize overlays mean a shared fix (e.g. a new probe) is made once
     in `base/` and picked up by every app.

### Validating locally

```bash
kustomize build k8s/overlays/production
# or
kubectl apply -k k8s/overlays/production --dry-run=client
```
