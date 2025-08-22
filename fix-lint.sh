#!/bin/bash
set -euo pipefail

CHARTS=("api-gateway" "orders" "payments" "users")
TMP_DIR="/tmp/helm-lint"   # <<< fixed: use a stable dir kubeconform can read
ARGOCD_DIR="argocd/apps"
EXIT_CODE=0

mkdir -p "$TMP_DIR"

echo ">>> Rendering Helm charts..."
for chart in "${CHARTS[@]}"; do
    echo " - $chart"
    helm template "charts/$chart" > "$TMP_DIR/$chart.yaml"
done

echo ">>> Collecting ArgoCD app YAMLs..."
if [ -d "$ARGOCD_DIR" ]; then
    cp "$ARGOCD_DIR"/*.yaml "$TMP_DIR/" || true
fi

echo ">>> Splitting multi-doc YAMLs..."
for file in "$TMP_DIR"/*.yaml; do
    if grep -q "^---" "$file"; then
        csplit -s -z -f "$file-" "$file" '/^---$/' '{*}' || true
        rm -f "$file"
    fi
done

echo ">>> Running yamllint..."
for file in "$TMP_DIR"/*; do
    if ! yamllint -d "{extends: default, rules: {line-length: {max: 120}, trailing-spaces: enable, indentation: {spaces: 2}, empty-values: disable}}" "$file"; then
        EXIT_CODE=1
    fi
done

# 🚫 DO NOT delete TMP_DIR, kubeconform needs these files
# rm -rf "$TMP_DIR"

if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ All Helm charts and ArgoCD YAMLs passed lint!"
else
    echo -e "\n❌ Lint errors detected. See above for details."
fi

exit $EXIT_CODE
