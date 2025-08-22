#!/bin/bash
set -euo pipefail

CHARTS=("api-gateway" "orders" "payments" "users")
TMP_DIR="/tmp/helm-lint"   # Use a stable dir kubeconform can read
RENDERED_DIR="rendered"
ARGOCD_DIR="argocd/apps"
EXIT_CODE=0

mkdir -p "$TMP_DIR"
mkdir -p "$RENDERED_DIR"

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

# Move all YAML files to the rendered directory
mv "$TMP_DIR"/*.yaml "$RENDERED_DIR/"

# Check if there are any YAML files in the rendered directory
if [ -z "$(ls -A "$RENDERED_DIR")" ]; then
    echo "❌ No YAML files found in the rendered directory."
    exit 1
fi

echo ">>> Running yamllint..."
for file in "$RENDERED_DIR"/*; do
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

# Run kubeconform if there are valid YAML files
if [ $EXIT_CODE -eq 0 ]; then
    echo ">>> Running kubeconform..."
    kubeconform -strict -summary -kubernetes-version "${KUBE_VERSION}" "$RENDERED_DIR"/*.yaml || EXIT_CODE=1
fi

exit $EXIT_CODE