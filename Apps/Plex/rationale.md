# Plex Configuration Rationale

This document explains the rationale behind specific configuration settings for the Plex app.

## Network Configuration

Plex uses standard bridge networking with port exposure (`expose: 32400`) for NSL Router compatibility. The Yundera NSL mesh router system requires bridge networking to properly route HTTPS traffic and generate clean URLs like `https://plex-username.nsl.sh/web`.

## Volume Mapping Strategy

The volume mapping `/DATA/AppData/$AppID:/config` allows the container full access to create required subdirectories like `Library/Application Support/Plex Media Server`, eliminating permission issues during initialization.

## Hardware Acceleration

**GPU Device Mapping**: The `/dev/dri:/dev/dri` device mapping enables hardware-accelerated transcoding via Intel Quick Sync, AMD VCE, or NVIDIA NVENC, significantly reducing CPU usage and power consumption while supporting more concurrent streams.

## Authentication

Authentication is managed by Plex itself through its built-in user management system:
* Plex account integration via PLEX_CLAIM token
* Multi-user support with individual libraries
* Remote access authentication
* Parental controls and user permissions

## Resource Limits

**Memory Limit (1GB)**: Sufficient for typical transcoding operations while preventing OOM conditions.

**CPU Limit (0.5 cores)**: Provides balanced CPU allocation for transcoding tasks while maintaining system responsiveness.