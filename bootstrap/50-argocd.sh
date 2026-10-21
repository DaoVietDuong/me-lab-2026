#!/usr/bin/env bash
# Build step 3a: install Argo CD once, then hand the platform to Git (platform/apps/root.yaml).
# Run from Windows Git Bash after 40-k3s.sh. Push the repo first: Argo CD syncs from GitHub, not from disk.
set -euo pipefail
cd "$(dirname "$0")/.."
KC="kubectl --kubeconfig $HOME/.kube/lab.yaml"
step() { printf '\n== %s\n' "$*"; }

step "Argo CD (kustomize: upstream install + lab patches)"
$KC apply --server-side --force-conflicts -k platform/argocd | grep -vE 'serverside-applied$' || true
for d in argocd-server argocd-repo-server argocd-redis argocd-applicationset-controller; do
    $KC -n argocd rollout status deploy/$d --timeout=10m
done
$KC -n argocd rollout status statefulset/argocd-application-controller --timeout=10m

step "Root app: from here on, Git is the source of truth"
$KC apply -f platform/apps/root.yaml

step "Waiting for all apps to be Synced + Healthy (up to 10 min)"
for i in $(seq 1 60); do
    out=$($KC -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers 2>/dev/null || true)
    total=$(echo "$out" | grep -c . || true)
    ok=$(echo "$out" | grep -c 'Synced *Healthy' || true)
    [ "$total" -ge 5 ] && [ "$ok" -eq "$total" ] && break
    sleep 10
done
echo "$out"

step "Argo CD login"
echo "URL:      https://argocd.apps.lab"
echo "User:     admin"
echo "Password: $KC -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
