# FAQ

**Why was Palmier Pro built?**

We are a YC startup that has been making AI launch videos for other companies. We noticed a big gap between generative AI and the video editor, so we built this to solve our biggest pain points. First, let's talk about how we make our AI videos better:

1. many iterations
2. many editing

With these two requirements, the pain points we've encountered:

1. Most generative platforms live on the web. To make a production-grade video, we have to go through the editing process inside the video editor. So each iteration looks like: generate on the web → download to your laptop → import to your timeline editor → replace the clip and redo the editing → repeat.
2. Projects get large, and they become extremely hard to maintain. We have files of all the versions of each shot, which require us to manually rename them to stay organized. We have context spread across different AI agents that we talk to: Claude for scripting, AI chat from the generative platform for generation.

So we built Palmier Pro to solve these issues. The video editor is the single source of truth. You can use your own AI agent to do scripting, generating, and editing with all the context you need.

**Do you have feature parity with Adobe Premiere Pro or CapCut?**

Not yet. This is still a very early product with a small team behind it, but we are pushing it to get better every day. To give you a clear list:

What we don't have yet:

1. Transitions
2. Masking
3. Graphics

We launched it because it was enough for us to make professional AI videos. We acknowledge that without AI features, this is quite a bare-bone video editor. That's why we decided to open source it and release the video editor for free, because we want to improve the product with the community.

**What's the difference between MCP server and the in-app chat?**

They share the same prompt and tools. The MCP server is free to use for your MCP clients, and the in-app chat requires either BYOK or subscription. The differences are mostly the UX.

In-app chat:
1. You can @ to reference media, which is particularly useful when iterating on generative media. 
2. Less context switching. It lives right inside the timeline.
3. It has more control on the context window.

External chat with MCP server:
1. Centralized spending on tokens. You don't have to worry about paying for another service.
2. A more mature chat client. Claude/Cursor/Codex handles context window/memory/web search and they will continue to get better.
3. Much more interesting use cases with integrating with other workflows. Since Palmier Pro is just a MCP server, you can connect your video editor with other MCP servers all in one chat, so context is centralized.

Some examples on using Palmier Pro MCP server with Claude:

1. Write your idea and script in Claude, then ask it to generate videos inside Palmier Pro
2. Pull sound effect from Epidemic Sound MCP server and import to Palmier Pro MCP server
3. Pull your team's idea in #marketing Slack channel and create a quick prototype in Palmier Pro

**What models are supported?**

We support most SOTA generation models. For images, the most common ones are Nano Banana Pro, GPT-image-2. For videos, Seedance2, Kling3, Grok, Veo, etc. We constantly push update for more. For the in-app chat, only Anthropic at the moment. But you can connect with MCP to try other models.

**What is the future of Palmier Pro?**

We envision Palmier Pro as the future of video editing, a UI for both humans and agents. We strongly believe agents cannot replicate human creativity, but in the process of generating and editing videos, there is a lot of manual work that AI can help with.