#!/usr/bin/env bash
#
# setup.sh
#
# Sets up the project folder structure for the thesis codebase.
# This script lives at the root of its own dedicated repo, and builds the
# folder structure right there alongside itself (no parent directory needed).
# The data preprocessing / evaluation code itself is cloned into Src/.
#
# Resulting layout:
#
# <this-repo>/                (project folder structure)
# ├── Src/                    (Utility codes for data preprocessing, evaluating, 
# |                            comparison code and scripts to run the experiments are here)
# ├── Models/                 (each segmentation model's repo cloned here)
# ├── ModelResults/           (each model's outputs/results)
# |   ├── checkpoints/        (the generated models)
# |   └── images/             (the inferenced images)
# └── Datasets/
#     ├── raw/
#     └── preprocessed/
#
# Usage:
#   ./setup.sh
#
# Optional: to auto-clone your preprocessing/evaluation repo into Src/,
# create a file named "src_repo.txt" next to this script, containing a
# single line:
#
#   https://github.com/yourname/thesis-preprocessing.git
#   https://github.com/yourname/thesis-preprocessing.git src-env
#
# Columns (space-separated): URL  [conda_env_name]
#   - conda_env_name defaults to "src" if omitted
# If src_repo.txt doesn't exist, Src/ is still created but left empty, and
# the script tells you how to clone it manually.
#
# Optional: to auto-clone your model repos, create a file named "models.txt"
# next to this script (same folder), with one Git URL per line, e.g.:
#
#   https://github.com/yourname/unet-forked.git
#   https://github.com/yourname/segformer-forked.git my-custom-name
#
# Columns (space-separated): URL  [folder_name]  [conda_env_name]
#   - folder_name defaults to the repo name if omitted
#   - conda_env_name defaults to folder_name if omitted
# If models.txt doesn't exist, the script just creates empty folders and
# tells you how to clone your repos manually.
#
# For each cloned repo, this script also creates a conda environment:
#   1. If the repo has environment.yml / environment.yaml -> create env from it
#   2. Else if the repo has requirements.txt -> create a bare env (latest
#      python 3) and pip-install from requirements.txt into it
#   3. Else -> create a bare env and print a reminder to fill in dependencies
# Existing envs (matching name) are left alone (skipped), so this is safe
# to re-run.
#
# Additionally, this script exports a shared set of PROJECT PATH variables
# into every conda env it manages (via `conda env config vars set`), so that
# model code can read them the same way regardless of which env is active:
#
#   MAIN_REPO_DIR            -> this directory (repo's own path)
#   MODELS_DIR               -> Models/
#   MODEL_CHECKPOINTS_DIR     -> ModelResults/checkpoints
#   MODEL_INFERENCES_DIR      -> ModelResults/images
#   DATASETS_RAW              -> Datasets/raw/
#   DATASETS_PREPROCESSED     -> Datasets/preprocessed/
#
# These take effect the next time each env is activated (conda activate <env>).
# If this script itself is run from inside an already-active conda env
# (e.g. your main preprocessing env), that env gets the same variables too.
#
# Requires: conda (or miniconda/mambaforge) available on PATH.

set -euo pipefail

# --- Resolve paths relative to THIS script, not the current working directory ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_NAME="$(basename "$SCRIPT_DIR")"

MODELS_DIR="$SCRIPT_DIR/Models"
SRC_DIR="$SCRIPT_DIR/Src"
RESULTS_DIR="$SCRIPT_DIR/ModelResults"
CHECKPOINTS_DIR="$RESULTS_DIR/checkpoints"
IMAGES_DIR="$RESULTS_DIR/images"
DATASETS_DIR="$SCRIPT_DIR/Datasets"
RAW_DIR="$DATASETS_DIR/raw"
PREPROCESSED_DIR="$DATASETS_DIR/preprocessed"
MODELS_LIST="$SCRIPT_DIR/models.txt"
SRC_REPO_FILE="$SCRIPT_DIR/src_repo.txt"

# --- Check conda availability up front (needed for env creation later) ---
CONDA_AVAILABLE=1
if ! command -v conda >/dev/null 2>&1; then
    CONDA_AVAILABLE=0
fi

echo "=================================================="
echo " Thesis project setup"
echo "=================================================="
echo "Main repo:   $SCRIPT_DIR"
echo "--------------------------------------------------"

# --- Create folder structure (idempotent: -p won't error if it already exists) ---
mkdir -p "$SRC_DIR"
mkdir -p "$MODELS_DIR"
mkdir -p "$CHECKPOINTS_DIR"
mkdir -p "$IMAGES_DIR"
mkdir -p "$RAW_DIR"
mkdir -p "$PREPROCESSED_DIR"

echo "Created (or confirmed) the following folders:"
echo "  - $SRC_DIR"
echo "  - $MODELS_DIR"
echo "  - $CHECKPOINTS_DIR"
echo "  - $IMAGES_DIR"
echo "  - $RAW_DIR"
echo "  - $PREPROCESSED_DIR"
echo "--------------------------------------------------"

# --- Helper: handle extra pre-install pip commands and local editable packages ---
# Looks for two optional files in $target_dir:
#   pre_install.txt   -> one full 'pip install ...' args per line, run BEFORE local packages
#                        (e.g. torch with a custom --index-url)
#   local_packages.txt -> one subfolder name per line, each installed via
#                        'pip install --no-build-isolation -e <folder>'
#                        (use this for setup.py packages with CUDAExtension/cpp_extension deps)
install_repo_extras() {
    local target_dir="$1"
    local env_name="$2"

    local pre_install_file="$target_dir/pre_install.txt"
    local local_pkgs_file="$target_dir/local_packages.txt"

    if [[ -f "$pre_install_file" ]]; then
        echo "    [conda] running pre-install pip commands for '$env_name' ..."
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" =~ ^# ]] && continue   # skip blanks/comments
            echo "        pip install $line"
            conda run -n "$env_name" pip install $line
        done < "$pre_install_file"
    fi

    if [[ -f "$local_pkgs_file" ]]; then
        echo "    [conda] building local packages for '$env_name' ..."
        while IFS= read -r pkg_dir || [[ -n "$pkg_dir" ]]; do
            [[ -z "$pkg_dir" || "$pkg_dir" =~ ^# ]] && continue
            echo "        pip install --no-build-isolation -e $target_dir/$pkg_dir"
            conda run -n "$env_name" pip install --no-build-isolation -e "$target_dir/$pkg_dir"
        done < "$local_pkgs_file"
    fi
}

# --- Helper: create a conda env for a given repo folder, if needed ---
create_conda_env_for_repo() {
    local target_dir="$1"
    local env_name="$2"

    if [[ "$CONDA_AVAILABLE" -eq 0 ]]; then
        echo "    [conda] conda not found on PATH — skipping env creation for '$env_name'."
        echo "            Install miniconda/conda and re-run to create it."
        return
    fi

    # Skip if the env already exists
    if conda env list | awk '{print $1}' | grep -qx "$env_name"; then
        echo "    [conda] env '$env_name' already exists — skipping."
        return
    fi

    local env_yml=""
    if [[ -f "$target_dir/environment.yml" ]]; then
        env_yml="$target_dir/environment.yml"
    elif [[ -f "$target_dir/environment.yaml" ]]; then
        env_yml="$target_dir/environment.yaml"
    fi

    if [[ -n "$env_yml" ]]; then
    echo "    [conda] creating env '$env_name' from $(basename "$env_yml") ..."
    (
        cd "$target_dir" || exit 1
        conda env create -n "$env_name" -f "$env_yml"
    )
    install_repo_extras "$target_dir" "$env_name"
    # subshell exits here — we're automatically back in the original directory
    elif [[ -f "$target_dir/requirements.txt" ]]; then
        echo "    [conda] no environment.yml found; creating bare env '$env_name' (python 3)"
        echo "            and installing from requirements.txt via pip ..."
        conda create -y -n "$env_name" python=3
        conda run -n "$env_name" pip install -r "$target_dir/requirements.txt"
    else
        echo "    [conda] no environment.yml or requirements.txt found in $target_dir."
        echo "            Creating bare env '$env_name' (python 3) — add dependencies manually,"
        echo "            or add an environment.yml/requirements.txt to the repo and re-run."
        conda create -y -n "$env_name" python=3
    fi
}

# --- Helper: export the shared project path variables into a conda env ---
# These are the SAME across every env, so model code can rely on them
# regardless of which env is active.
set_project_path_vars() {
    local env_name="$1"

    if [[ "$CONDA_AVAILABLE" -eq 0 ]]; then
        return
    fi

    echo "    [conda] setting shared project path variables on env '$env_name' ..."
    conda env config vars set -n "$env_name" \
        MAIN_REPO_DIR="$SCRIPT_DIR" \
        MODELS_DIR="$MODELS_DIR" \
        MODEL_CHECKPOINTS_DIR="$CHECKPOINTS_DIR" \
        MODEL_INFERENCES_DIR="$IMAGES_DIR" \
        DATASETS_RAW="$RAW_DIR" \
        DATASETS_PREPROCESSED="$PREPROCESSED_DIR" \
        >/dev/null
}

# --- Clone the main preprocessing/evaluation repo into Src/, if configured ---
# Reads a single line from src_repo.txt: "<git-url> [conda_env_name]"
# (conda_env_name is optional, defaults to "src")
clone_src_repo() {
    if [[ ! -f "$SRC_REPO_FILE" ]]; then
        echo "No src_repo.txt found next to this script."
        echo "To auto-clone your preprocessing/evaluation repo into Src/, create:"
        echo "  $SRC_REPO_FILE"
        echo "containing one line: '<git-url> [conda_env_name]'"
        echo "For now, clone it manually into: $SRC_DIR"
        return
    fi

    local line url custom_env env_name
    line=$(grep -vE '^[[:space:]]*(#|$)' "$SRC_REPO_FILE" | head -n 1)
    if [[ -z "$line" ]]; then
        echo "src_repo.txt exists but contains no URL — skipping Src/ clone."
        return
    fi

    url=$(echo "$line" | awk '{print $1}')
    custom_env=$(echo "$line" | awk '{print $2}')
    env_name="${custom_env:-src}"

    echo "Found src_repo.txt — cloning preprocessing/evaluation repo into Src/ ..."
    if [[ -d "$SRC_DIR/.git" ]]; then
        echo "  [pull] $SRC_DIR already exists, pulling latest changes ..."
        git -C "$SRC_DIR" pull --ff-only || echo "  [warning] git pull failed in $SRC_DIR (check for local changes or uncommitted work)."
    else
        echo "  [clone] $url -> $SRC_DIR"
        git clone "$url" "$SRC_DIR"
    fi

    create_conda_env_for_repo "$SRC_DIR" "$env_name"
    set_project_path_vars "$env_name"
}

clone_src_repo
echo "--------------------------------------------------"

# --- Optionally clone model repos listed in models.txt, and create conda envs ---
if [[ -f "$MODELS_LIST" ]]; then
    echo "Found models.txt — cloning listed repositories into Models/ ..."
    if [[ "$CONDA_AVAILABLE" -eq 0 ]]; then
        echo "  NOTE: 'conda' was not found on PATH — repos will still be cloned,"
        echo "        but conda environments will NOT be created automatically."
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        # skip blank lines and comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        url=$(echo "$line" | awk '{print $1}')
        custom_name=$(echo "$line" | awk '{print $2}')
        custom_env=$(echo "$line" | awk '{print $3}')

        if [[ -n "$custom_name" ]]; then
            target_dir="$MODELS_DIR/$custom_name"
        else
            repo_basename="$(basename "$url" .git)"
            target_dir="$MODELS_DIR/$repo_basename"
        fi

        env_name="${custom_env:-$(basename "$target_dir")}"

        if [[ -d "$target_dir/.git" ]]; then
            echo "  [pull] $target_dir already exists, pulling latest changes ..."
            git -C "$target_dir" pull --ff-only || echo "  [warning] git pull failed in $target_dir (check for local changes or uncommitted work)."
        else
            echo "  [clone] $url -> $target_dir"
            git clone "$url" "$target_dir"
        fi

        create_conda_env_for_repo "$target_dir" "$env_name"
        set_project_path_vars "$env_name"
    done < "$MODELS_LIST"
else
    echo "No models.txt found next to this script."
    echo "To auto-clone your model repos next time, create:"
    echo "  $MODELS_LIST"
    echo "with one Git URL per line: 'URL [folder_name] [conda_env_name]'."
    echo "For now, clone your model repos manually into:"
    echo "  $MODELS_DIR"
    echo "and create their conda environments by hand (conda env create -f environment.yml)."
fi

echo "--------------------------------------------------"

# --- Also apply the shared path vars to the currently active conda env, ---
# --- if any (e.g. your main preprocessing env) ---
if [[ "$CONDA_AVAILABLE" -eq 1 && -n "${CONDA_DEFAULT_ENV:-}" && "${CONDA_DEFAULT_ENV}" != "base" ]]; then
    echo "Detected active conda env '$CONDA_DEFAULT_ENV' — applying shared path variables to it too."
    set_project_path_vars "$CONDA_DEFAULT_ENV"
elif [[ "$CONDA_AVAILABLE" -eq 1 ]]; then
    echo "No non-base conda env currently active — skipping path-var setup for the main repo's env."
    echo "Activate your main repo's env and re-run this script (or run"
    echo "  conda env config vars set -n <your-env> MAIN_REPO_DIR=$SCRIPT_DIR ..."
    echo "manually) to give it the same path variables."
fi

echo "--------------------------------------------------"
echo "Setup complete. Final structure:"
echo ""

# --- Print the resulting structure (uses 'tree' if available, else a fallback) ---
if command -v tree >/dev/null 2>&1; then
    tree -L 3 "$SCRIPT_DIR"
else
    echo "$REPO_NAME/         (this repo)"
    echo "├── Src/"
    echo "├── Models/"
    for d in "$MODELS_DIR"/*/; do
        [[ -d "$d" ]] || continue
        echo "│   ├── $(basename "$d")"
    done
    echo "├── ModelResults/"
    echo "│   ├── checkpoints/"
    echo "│   └── images/"
    echo "└── Datasets/"
    echo "    ├── raw/"
    echo "    └── preprocessed/"
fi

echo ""
echo "Done."
echo ""
if [[ "$CONDA_AVAILABLE" -eq 1 ]]; then
    echo "NOTE: shared path variables (MAIN_REPO_DIR, DATASETS_RAW, etc.) only"
    echo "take effect the NEXT time each env is activated. If an env was already"
    echo "active before/during this run, deactivate and reactivate it to pick them up:"
    echo "  conda deactivate && conda activate <env-name>"
    echo "  conda env config vars list -n <env-name>   # to inspect what's set"
fi