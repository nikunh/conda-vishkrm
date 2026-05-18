#!/bin/bash
set -e

# Audit fix 2026-05-15: resolve runtime user/home/group dynamically (no hardcoded babaji)
USERNAME="${USERNAME:-${_REMOTE_USER:-}}"
if [ -z "$USERNAME" ] || [ "$USERNAME" = "root" ]; then
    if getent passwd vishkrm >/dev/null 2>&1; then
        USERNAME=vishkrm
    else
        USERNAME=$(getent passwd | awk -F: '$3>=1000 && $1!="nobody" {print $1; exit}')
    fi
fi
USER_HOME="$(getent passwd "$USERNAME" 2>/dev/null | cut -d: -f6)"
[ -z "$USER_HOME" ] && USER_HOME="/home/${USERNAME}"
USER_GROUP="$(id -gn "$USERNAME" 2>/dev/null || echo users)"

# Install Miniconda if not already available via the official DevContainer feature
# This feature supplements the official conda feature with proper PATH setup
if ! command -v conda &> /dev/null; then
    echo "Installing Miniconda..."
    
    # Clean up any existing miniconda directories
    if [ -d "$USER_HOME/miniconda" ]; then
        rm -rf "$USER_HOME/miniconda"
    fi
    
    # Download and install Miniconda with architecture detection
    if [ "$(uname -m)" = "x86_64" ]; then
        ARCH=x86_64
    else
        ARCH=aarch64
    fi
    wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-${ARCH}.sh -O /tmp/miniconda.sh
    bash /tmp/miniconda.sh -b -p "$USER_HOME/miniconda"
    rm /tmp/miniconda.sh
    
    # Fix ownership if needed
    if [ "$USER" != "$USERNAME" ]; then
        chown -R "${USERNAME}:${USER_GROUP}" "$USER_HOME/miniconda" 2>/dev/null || true
    fi
fi

# 🧩 Create Self-Healing Environment Fragment
create_environment_fragment() {
    local feature_name="conda"
    
    # Create authoritative fragment in image
    local fragment_source_dir="/etc/skel/.devcontainer-fragments"
    mkdir -p "$fragment_source_dir"
    local fragment_source_file="$fragment_source_dir/.${feature_name}.zshrc"
    
    # Create fragment content with self-healing detection
    # Create fragment content with self-healing detection
    cat > "$fragment_source_file" << 'EOF'
# 🐍 Conda Environment Fragment (Symlink-based v2.0)
# Self-healing detection and environment setup

# Check if conda is available
conda_available=false

# Check for conda in common locations
if command -v conda >/dev/null 2>&1; then
    conda_available=true
else
    # Check official conda locations
    for conda_path in "/opt/conda/bin" "$HOME/miniconda/bin" "$HOME/anaconda3/bin"; do
        if [ -d "$conda_path" ] && [ -x "$conda_path/conda" ]; then
            if [[ ":$PATH:" != *":$conda_path:"* ]]; then
                export PATH="$conda_path:$PATH"
            fi
            conda_available=true
            break
        fi
    done
fi

# Initialize conda if available
if [ "$conda_available" = true ]; then
    # >>> conda initialize >>>
    __conda_setup="$(conda shell.zsh hook 2>/dev/null)"
    if [ $? -eq 0 ]; then
        eval "$__conda_setup"
    else
        # Try common conda.sh locations
        for conda_sh in "/opt/conda/etc/profile.d/conda.sh" "$HOME/miniconda/etc/profile.d/conda.sh" "$HOME/anaconda3/etc/profile.d/conda.sh"; do
            if [ -f "$conda_sh" ]; then
                source "$conda_sh"
                break
            fi
        done
        # Activate base environment if conda is available
        if command -v conda >/dev/null 2>&1; then
            conda activate base 2>/dev/null || true
        fi
    fi
    unset __conda_setup
    # <<< conda initialize <<<
fi

# If conda is not available, cleanup this fragment
if [ "$conda_available" = false ]; then
    echo "Conda removed, cleaning up environment"
    rm -f "$HOME/.ohmyzsh_source_load_scripts/.conda.zshrc"
fi
EOF

    # Create fragment for /etc/skel
    if [ -d "/etc/skel/.ohmyzsh_source_load_scripts" ]; then
        cp "$fragment_source_file" "$fragment_file_skel"
    fi

    # Create fragment for existing user
    if [ -d "$USER_HOME/.ohmyzsh_source_load_scripts" ]; then
        cp "$fragment_source_file" "$fragment_file_user"
        if [ "$USER" != "$USERNAME" ]; then
            chown "${USERNAME}:${USER_GROUP}" "$fragment_file_user" 2>/dev/null || true
        fi
    elif [ -d "$USER_HOME" ]; then
        # Create the directory if it doesn't exist
        mkdir -p "$USER_HOME/.ohmyzsh_source_load_scripts"
        cp "$fragment_source_file" "$fragment_file_user"
        if [ "$USER" != "$USERNAME" ]; then
            chown -R "${USERNAME}:${USER_GROUP}" "$USER_HOME/.ohmyzsh_source_load_scripts" 2>/dev/null || true
        fi
    fi
    
    echo "Self-healing environment fragment created: .conda.zshrc"
}

# Call the fragment creation function
create_environment_fragment

echo "Conda configuration completed."

# Clean up
sudo apt-get clean
