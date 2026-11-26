# Headless & Cross-Platform Rendering Guide

This document describes how to execute headless, CI/CD, and cross-platform video rendering pipelines using Compositor Pro and HyperFrames.

## 1. Exporting a Headless Render Job

From macOS, export a standalone JSON render job from any `.compositorpro` project package:

```bash
compositor-pro export-job path/to/project.compositorpro -o job.json
```

The exported `job.json` contains:
- Video dimensions, frame rate (`fps`), and total frame count.
- Track layouts and clips (including native video and HTML composition blocks).
- Embedded parameter bindings and styling overrides.

## 2. Cross-Platform Execution (Linux / Windows)

The headless runner (`scripts/headless/render_job.js`) executes in standard container environments (Docker, GitHub Actions, AWS ECS/Lambda):

```bash
node scripts/headless/render_job.js job.json output.mp4
```

### Docker Container

Build and run using the provided Dockerfile:

```bash
docker build -t compositor-headless -f scripts/headless/Dockerfile scripts/headless
docker run --rm -v $(pwd):/workspace compositor-headless /workspace/job.json /workspace/output.mp4
```

## 3. Extended Community Catalog Management

Manage community motion templates using the CLI:

```bash
# List all built-in and installed community templates
compositor-pro catalog list

# Validate a template package
compositor-pro catalog validate path/to/template-folder

# Install a community template package
compositor-pro catalog add path/to/template-folder
```

