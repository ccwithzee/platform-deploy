#!/bin/bash
set -euo pipefail

# Always run relative to the script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CHARTS=("api-gateway" "orders" "payments" "users")
TMP_DIR="$SCRIPT_DIR/tmp_helm_lint"
RENDERED_DIR="$SCRIPT_DIR/rendered"
ARGOCD_DIR="$SCRIPT_DIR/argocd/apps"
CRD_SCHEMA_DIR="$SCRIPT_DIR/crd-schemas"
EXIT_CODE=0

# Create directories
mkdir -p "$CRD_SCHEMA_DIR" "$TMP_DIR" "$RENDERED_DIR"

# Check kubeconform availability
KUBECONFORM_AVAILABLE=true
if ! command -v kubeconform &>/dev/null; then
    echo "⚠️  kubeconform not installed or not in PATH → Kubernetes validation skipped."
    KUBECONFORM_AVAILABLE=false
fi

# Clean old rendered files but keep CRD schemas (they take time to download)
rm -rf "$TMP_DIR" "$RENDERED_DIR"/*.yaml
mkdir -p "$TMP_DIR" "$RENDERED_DIR"

# Download ArgoCD CRD schemas if kubeconform is available
if [ "$KUBECONFORM_AVAILABLE" = true ]; then
    echo ">>> Downloading ArgoCD CRD schemas..."
    APPLICATION_CRD_URL="https://raw.githubusercontent.com/argoproj/argo-cd/master/manifests/crds/application-crd.yaml"
    APPLICATION_SET_CRD_URL="https://raw.githubusercontent.com/argoproj/argo-cd/master/manifests/crds/applicationset-crd.yaml"
    APP_PROJECT_CRD_URL="https://raw.githubusercontent.com/argoproj/argo-cd/master/manifests/crds/appproject-crd.yaml"
    
    for url in "$APPLICATION_CRD_URL" "$APPLICATION_SET_CRD_URL" "$APP_PROJECT_CRD_URL"; do
        filename=$(basename "$url")
        if [ ! -f "$CRD_SCHEMA_DIR/$filename" ]; then
            if curl -s -f "$url" -o "$CRD_SCHEMA_DIR/$filename"; then
                echo "   ✅ Downloaded $filename"
            else
                echo "   ❌ Failed to download $filename"
                KUBECONFORM_AVAILABLE=false
            fi
        else
            echo "   ✅ Using cached $filename"
        fi
    done
fi

echo ">>> Rendering Helm charts..."
for chart in "${CHARTS[@]}"; do
    echo " - Rendering $chart"
    if ! helm template "$SCRIPT_DIR/charts/$chart" >"$TMP_DIR/$chart.yaml" 2>/dev/null; then
        echo "   ❌ Failed to render $chart"
        EXIT_CODE=1
        continue
    fi

    if [ ! -s "$TMP_DIR/$chart.yaml" ]; then
        echo "   ⚠️  Empty render for $chart"
        rm -f "$TMP_DIR/$chart.yaml"
    else
        echo "   ✅ Rendered $chart"
    fi
done

echo ">>> Collecting ArgoCD app YAMLs..."
if [ -d "$ARGOCD_DIR" ]; then
    shopt -s nullglob
    files=("$ARGOCD_DIR"/*.yaml)
    if [ ${#files[@]} -gt 0 ]; then
        cp "$ARGOCD_DIR"/*.yaml "$TMP_DIR/"
        echo "   ✅ Copied ${#files[@]} ArgoCD YAML(s)"
    else
        echo "   ⚠️  No YAMLs found in $ARGOCD_DIR"
    fi
else
    echo "   ⚠️  Directory $ARGOCD_DIR not found"
fi

echo ">>> Processing YAML files..."
for file in "$TMP_DIR"/*.yaml; do
    [ -f "$file" ] || continue
    echo "   Processing: $(basename "$file")"
    if grep -q "^---" "$file"; then
        echo "   Splitting multi-doc YAML..."
        SPLIT_DIR="${file%.yaml}_split"
        mkdir -p "$SPLIT_DIR"
        if csplit -s -z -f "$SPLIT_DIR/part-" "$file" '/^---$/' '{*}' 2>/dev/null; then
            for split_file in "$SPLIT_DIR"/*; do
                [ -s "$split_file" ] && mv "$split_file" "$TMP_DIR/$(basename "$file" .yaml)_$(basename "$split_file").yaml"
            done
            rm -rf "$SPLIT_DIR" "$file"
        else
            echo "   ⚠️  Failed split → keeping original"
        fi
    fi
done

echo ">>> Moving to rendered/"
shopt -s nullglob
files=("$TMP_DIR"/*.yaml)
if [ ${#files[@]} -gt 0 ]; then
    mv "$TMP_DIR"/*.yaml "$RENDERED_DIR/"
    echo "   ✅ Moved ${#files[@]} file(s)"
else
    echo "   ❌ No YAMLs to move"
    EXIT_CODE=1
fi

echo ">>> Running yamllint..."
for file in "$RENDERED_DIR"/*.yaml; do
    [ -f "$file" ] || continue
    echo "   Linting: $(basename "$file")"
    if ! yamllint -d "{extends: default, rules: {line-length: {max: 120}, trailing-spaces: enable, indentation: {spaces: 2}, empty-values: disable}}" "$file"; then
        EXIT_CODE=1
    fi
done

# --- kubeconform with ArgoCD schemas ---
if [ "$KUBECONFORM_AVAILABLE" = true ]; then
    echo ">>> Running kubeconform..."
    
    # Use the actual CRD YAML files as schemas (not extracted JSON)
    SCHEMAS=(
        "-schema-location" "default"
        "-schema-location" "$CRD_SCHEMA_DIR/application-crd.yaml"
        "-schema-location" "$CRD_SCHEMA_DIR/applicationset-crd.yaml"
        "-schema-location" "$CRD_SCHEMA_DIR/appproject-crd.yaml"
    )

    shopt -s nullglob
    files=("$RENDERED_DIR"/*.yaml)
    if [ ${#files[@]} -gt 0 ]; then
        if ! kubeconform -strict -summary "${SCHEMAS[@]}" "${files[@]}"; then
            EXIT_CODE=1
        fi
    else
        echo "   ⚠️  No files to validate"
    fi
fi

rm -rf "$TMP_DIR"

if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ All checks passed clean!"
else
    echo -e "\n❌ Validation failed — see logs above."
fi

exit $EXIT_CODE