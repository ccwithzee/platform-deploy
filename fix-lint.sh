#!/bin/bash
set -euo pipefail

CHARTS=("api-gateway" "orders" "payments" "users")
TMP_DIR="/tmp/helm-lint"
RENDERED_DIR="rendered"
ARGOCD_DIR="argocd/apps"
EXIT_CODE=0

# Clean and create directories
rm -rf "$TMP_DIR" "$RENDERED_DIR"
mkdir -p "$TMP_DIR"
mkdir -p "$RENDERED_DIR"

echo ">>> Rendering Helm charts..."
for chart in "${CHARTS[@]}"; do
    echo " - Rendering $chart"
    if ! helm template "charts/$chart" > "$TMP_DIR/$chart.yaml" 2>/dev/null; then
        echo "   ❌ Failed to render $chart chart"
        EXIT_CODE=1
        continue
    fi
    
    # Check if the file was actually created and has content
    if [ ! -s "$TMP_DIR/$chart.yaml" ]; then
        echo "   ⚠️  No content generated for $chart chart"
        rm -f "$TMP_DIR/$chart.yaml"
    else
        echo "   ✅ Successfully rendered $chart"
    fi
done

echo ">>> Collecting ArgoCD app YAMLs..."
if [ -d "$ARGOCD_DIR" ]; then
    if ls "$ARGOCD_DIR"/*.yaml 1> /dev/null 2>&1; then
        cp "$ARGOCD_DIR"/*.yaml "$TMP_DIR/" || true
        echo "   ✅ Copied ArgoCD YAML files"
    else
        echo "   ⚠️  No YAML files found in $ARGOCD_DIR"
    fi
else
    echo "   ⚠️  ArgoCD directory $ARGOCD_DIR not found"
fi

echo ">>> Processing YAML files in $TMP_DIR..."
# Find all YAML files and process them
find "$TMP_DIR" -name "*.yaml" -type f | while read -r file; do
    echo "   Processing: $(basename "$file")"
    
    # Check if it's a multi-document YAML
    if grep -q "^---" "$file"; then
        echo "   Splitting multi-document YAML..."
        # Create a temporary directory for split files
        SPLIT_DIR="$TMP_DIR/split_$(basename "$file" .yaml)"
        mkdir -p "$SPLIT_DIR"
        
        # Split the file and capture any errors
        if csplit -s -z -f "$SPLIT_DIR/part-" "$file" '/^---$/' '{*}' 2>/dev/null; then
            # Move split files to main directory with unique names
            for split_file in "$SPLIT_DIR"/*; do
                if [ -s "$split_file" ]; then
                    mv "$split_file" "$TMP_DIR/$(basename "$file" .yaml)_split_$(basename "$split_file").yaml"
                fi
            done
            rm -rf "$SPLIT_DIR"
            rm -f "$file"
        else
            echo "   ⚠️  Failed to split $(basename "$file"), keeping original"
        fi
    fi
done

echo ">>> Moving processed files to rendered directory..."
# Move all YAML files to rendered directory
if ls "$TMP_DIR"/*.yaml 1> /dev/null 2>&1; then
    mv "$TMP_DIR"/*.yaml "$RENDERED_DIR/"
    echo "   ✅ Moved $(ls -1 "$RENDERED_DIR" | wc -l) YAML files to $RENDERED_DIR"
else
    echo "   ❌ No YAML files found to move"
    EXIT_CODE=1
fi

echo ">>> Running yamllint..."
if [ -n "$(ls -A "$RENDERED_DIR")" ]; then
    for file in "$RENDERED_DIR"/*; do
        echo "   Linting: $(basename "$file")"
        if ! yamllint -d "{extends: default, rules: {line-length: {max: 120}, trailing-spaces: enable, indentation: {spaces: 2}, empty-values: disable}}" "$file"; then
            EXIT_CODE=1
        fi
    done
else
    echo "   ⚠️  No files to lint in $RENDERED_DIR"
    EXIT_CODE=1
fi

if [ $EXIT_CODE -eq 0 ] && [ -n "$(ls -A "$RENDERED_DIR")" ]; then
    echo "✅ All YAML files passed lint!"
    
    echo ">>> Running kubeconform..."
    if [ -n "${KUBE_VERSION:-}" ]; then
        kubeconform -strict -summary -kubernetes-version "${KUBE_VERSION}" "$RENDERED_DIR"/*.yaml || EXIT_CODE=1
    else
        echo "   ⚠️  KUBE_VERSION not set, skipping kubeconform"
    fi
else
    echo -e "\n❌ Errors detected during processing. See above for details."
fi

# Clean up
rm -rf "$TMP_DIR"

exit $EXIT_CODE
