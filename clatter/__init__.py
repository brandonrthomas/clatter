"""Clatter — a real-time message bus for Claude Code sessions.

This Python package is a thin delivery vehicle for the bash tool: `clatter install`
copies the scripts to ~/.claude/clatter and wires up the /clat command, hooks, and
systemd services. The tool itself is bash + jq + tmux; Python is only the installer.
"""
