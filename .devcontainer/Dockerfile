FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install Nix
RUN apt-get update && apt-get install -y \
  curl \
  xz-utils \
  sudo \
  && rm -rf /var/lib/apt/lists/*

# Create vscode user if it doesn't exist
RUN if ! id -u vscode > /dev/null 2>&1; then \
  useradd -m -s /bin/bash vscode && \
  echo "vscode ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers; \
  fi

# Switch to vscode user for Nix installation
USER vscode
WORKDIR /home/vscode

# Install Nix in single-user mode
RUN curl -L https://nixos.org/nix/install | sh -s -- --no-daemon

# Add Nix to PATH and configure for the shell
RUN echo '. /home/vscode/.nix-profile/etc/profile.d/nix.sh' >> /home/vscode/.bashrc && \
  mkdir -p /home/vscode/.config/nix && \
  echo 'experimental-features = nix-command flakes' >> /home/vscode/.config/nix/nix.conf

# Keep container running
CMD ["sleep", "infinity"]
