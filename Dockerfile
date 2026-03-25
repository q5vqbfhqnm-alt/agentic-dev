FROM node:22-slim

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    bash \
    ca-certificates \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y gh \
  && rm -rf /var/lib/apt/lists/*

# Claude Code + Codex CLIs (installed as root, available globally)
RUN npm install -g @anthropic-ai/claude-code @openai/codex

# Store the settings template where postCreateCommand can find it
# (can't bake into ~/.claude directly — that dir is a mounted volume at runtime)
COPY --chown=node:node .devcontainer/claude-settings.json /opt/agentic-dev-settings.json

# Pre-create ~/.claude owned by node so the named volume initializes with correct permissions
RUN mkdir -p /home/node/.claude && chown node:node /home/node/.claude

USER node

# Copy workflow files into the image
WORKDIR /opt/agentic-dev
COPY --chown=node:node . .

# Consumer project is mounted here at runtime
WORKDIR /workspace

ENTRYPOINT ["claude"]
