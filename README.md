<div align="center">

# Palmier Pro

**The video editor built for AI.**

<a href="https://github.com/palmier-io/palmier-pro/releases/latest/download/PalmierPro.dmg">
  <img src="./assets/macos-badge.png" alt="Download palmierpro for macOS" width="180" />
</a>

<sub><i>Requires macOS 26 (Tahoe)</i></sub>

</div>

<img src="./assets/palmier-ui.png" alt="palmierpro UI" width="900" />

---

## Features

### A full professional editor

We built Palmier Pro from scratch. The north star is Premiere Pro, with our take on integrating AI into the workflow. Currently:

- Multi-track compositing
- Trim, split, razor, ripple delete, speed, opacity, transform
- Keyframes
- Frame-accurate playback

### Built-in Generative AI

Generate videos and images with SOTA models like Seedance, Kling, Nano Banana Pro inside the timeline editor. We believe this is the easiest way to iterate and edit on production-ready videos.

- All footage lives inside the same project. Regenerate and edit clips without the back-and-forth import/export to your timeline editor.
- In-line replace AI-generated footage without redoing the timeline.

### Integrates with your agents

Each opened project comes with a local MCP server. Point Claude Desktop, Claude Code, Cursor, or any MCP client at it and your agent becomes a generative AI assistant for your timeline. Some capabilities:

- Generating images, videos, and audio
- Editing footage on the timeline
- Organizing and understanding your footage
- Generating transcription

It also includes a side-chat that uses your own Anthropic API key. It shares the same prompts and tools as the MCP server.

### And more
- Open source. The agent prompts/tools and the video editor are completely open-source. The generative AI processing is not.
- Lightweight and fast. Built as a native macOS app in Swift, with AVFoundation + Metal.

## Develop

Requires Xcode 16+ (Swift 6.2 toolchain).

```bash
git clone https://github.com/palmier-io/palmier-pro
cd palmier-pro

swift build
swift run
```

For a bundled debug build that launches the `.app` and streams OSLog:

```bash
./scripts/dev.sh
```

## FAQ

**Is Palmier Pro open source?**

The video editor (without the generative AI features) is fully open source. The MCP server and the agent chat are also open source. The only thing that is closed source is the generative AI processing.

**Is it free?**

The editor is free. You can download it with no login required, and use it as a video editor like CapCut or Adobe Premiere. You can also use the MCP server for free, and start experimenting using Claude Code/Desktop or Cursor to interact with your timeline editor.

What is not free is the Generative AI features.

Because we only target macOS 26, we are able to provide speech-to-text capabilities for free using the local SpeechTranscriber by Apple.

**What platforms does it support?**

macOS only, specifically macOS 26 (Tahoe) or later.

**Why was Palmier Pro built?**

We are a YC startup that has been making AI launch videos for other companies. We noticed a big gap between generative AI and the video editor, so we built this to solve our biggest pain points. First, let's talk about how we make our AI videos better:

1. many iterations
2. many editing

With these two requirements, the pain points we've encountered:

1. Most generative platforms live on the web. To make a production-grade video, we have to go through the editing process inside the video editor. So each iteration looks like: generate on the web → download to your laptop → import to your timeline editor → replace the clip and redo the editing → repeat.
2. Projects get large, and they become extremely hard to maintain. We have files of all the versions of each shot, which require us to manually rename them to stay organized. We have context spread across different AI agents that we talk to: Claude for scripting, AI chat from the generative platform for generation.

So we built Palmier Pro to solve these issues. The video editor is the single source of truth. You can use your own AI agent to do scripting, generating, and editing with all the context you need.

**What is the future of Palmier Pro?**

We envision Palmier Pro as the future of video editing, a UI for both humans and agents. We strongly believe agents cannot replicate human creativity, but in the process of generating and editing videos, there is a lot of manual work that AI can help with.

## License

Copyright (C) 2026 Palmier, Inc.

Palmier Pro is open source under [GPLv3](LICENSE).