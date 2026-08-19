import Foundation
import MCP

enum MCPPreviewApp {
    static let resourceURI = "ui://palmier/MCPPreviewApp.html"
    static let mimeType = "text/html;profile=mcp-app"
    static let pollerToolName = "get_generation_preview"
    static let revealToolName = "reveal_generation_media"
    static let previewResourcePrefix = "palmier://generation-preview/"
    static let generationMediaPrefix = "palmier://generation-media/"
    static let modelIconPrefix = "palmier://model-icon/"
    static let previewHTTPPathPrefix = "/preview/"
    static let previewMaxPixelSize = 512
    static let maxAudioPreviewBytes = 1_500_000
    static let maxHTTPMediaBytes = 80_000_000
    static let maxInlineMediaBytes = 24_000_000
    static let html = htmlSource

    static var previewOrigin: String { "http://127.0.0.1:\(MCPService.port)" }

    static func httpMediaURL(mediaRef: String) -> String {
        previewOrigin + previewHTTPPathPrefix + mediaRef
    }

    static func isPreviewMediaRef(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return (8...80).contains(value.count) && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func httpMediaMIMEType(url: URL, type: ClipType) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "gif": "image/gif"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "m4a", "aac": "audio/mp4"
        case "aiff", "aif", "aifc": "audio/aiff"
        case "caf": "audio/x-caf"
        case "flac": "audio/flac"
        case "ogg": "audio/ogg"
        default:
            switch type {
            case .image: "image/jpeg"
            case .video, .sequence: "video/mp4"
            case .audio: "audio/mpeg"
            case .text, .subtitle: "application/octet-stream"
            case .lottie: "application/json"
            }
        }
    }

    static var toolMeta: Metadata {
        Metadata(additionalFields: [
            "ui": .object(["resourceUri": .string(resourceURI)]),
        ])
    }

    static var pollerMeta: Metadata {
        Metadata(additionalFields: [
            "ui": .object(["visibility": .array([.string("app")])]),
        ])
    }

    static var resourceMeta: Metadata {
        let origin = Value.string(previewOrigin)
        return Metadata(additionalFields: [
            "ui": .object([
                "prefersBorder": .bool(false),
                "csp": .object([
                    "connectDomains": .array([origin]),
                    "resourceDomains": .array([origin, .string("blob:"), .string("data:")]),
                ]),
            ]),
        ])
    }

    static var resource: Resource {
        Resource(
            name: "Generated Media Preview",
            uri: resourceURI,
            description: "Inline preview card for generate_image, generate_video, and generate_audio",
            mimeType: mimeType,
            _meta: resourceMeta
        )
    }

    static func meta(for name: ToolName) -> Metadata? {
        switch name {
        case .generateImage, .generateVideo, .generateAudio, .showTimeline:
            toolMeta
        case .getGenerationPreview, .revealGenerationMedia, .revealTimeline:
            pollerMeta
        default:
            nil
        }
    }

    static func previewResourceURI(mediaRef: String) -> String {
        previewResourcePrefix + mediaRef
    }

    static func previewResourceMediaRef(_ uri: String) -> String? {
        guard uri.hasPrefix(previewResourcePrefix) else { return nil }
        let mediaRef = String(uri.dropFirst(previewResourcePrefix.count))
        return mediaRef.isEmpty ? nil : mediaRef
    }

    static func generationMediaURI(mediaRef: String) -> String {
        generationMediaPrefix + mediaRef
    }

    static func generationMediaRef(_ uri: String) -> String? {
        guard uri.hasPrefix(generationMediaPrefix) else { return nil }
        let mediaRef = String(uri.dropFirst(generationMediaPrefix.count))
        return isPreviewMediaRef(mediaRef) ? mediaRef : nil
    }

    static func modelIconKey(_ uri: String) -> String? {
        guard uri.hasPrefix(modelIconPrefix) else { return nil }
        let key = String(uri.dropFirst(modelIconPrefix.count))
        return key.isEmpty ? nil : key
    }

    nonisolated static func modelIconPNG(iconKey: String) -> Data? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard iconKey.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard let url = BundledResource.url("Images/LabLogos/logo-\(iconKey).png") else { return nil }
        return try? Data(contentsOf: url)
    }
}

extension MCPPreviewApp {
    private static let htmlSource = #"""
    <!doctype html>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Generated media</title>
    <style>
      :root {
        color-scheme: light dark;
        --bg: var(--color-background-primary, light-dark(#f4f4f5, #18181b));
        --elev: var(--color-background-secondary, light-dark(#ffffff, #27272a));
        --text: var(--color-text-primary, light-dark(#18181b, #fafafa));
        --muted: var(--color-text-secondary, light-dark(#71717a, #a1a1aa));
        --border: var(--color-border-primary, light-dark(#e4e4e7, #3f3f46));
        --fill: var(--color-background-tertiary, light-dark(#e4e4e7, #3f3f46));
      }
      html, body {
        margin: 0;
        background: transparent;
        color: var(--text);
        font: 12.5px/1.45 ui-sans-serif, system-ui, sans-serif;
      }
      .card { overflow: hidden; }
      .stage {
        position: relative;
        display: grid;
        place-items: center;
        overflow: hidden;
        background: color-mix(in srgb, var(--text) 6%, transparent);
        border-radius: 10px;
        aspect-ratio: var(--preview-aspect, 16 / 9);
      }
      .stage.portrait {
        max-height: 360px;
        width: min(100%, calc(360px * var(--preview-aspect)));
        margin-inline: auto;
      }
      .stage.audio { aspect-ratio: 16 / 6; }
      .stage img, .stage video {
        position: absolute;
        inset: 0;
        width: 100%;
        height: 100%;
        display: block;
      }
      .stage img { object-fit: contain; }
      .stage video { object-fit: cover; }
      .status { color: var(--muted); }
      .bars {
        display: flex;
        align-items: flex-end;
        gap: 4px;
        height: 28px;
      }
      .bars span {
        width: 4px;
        border-radius: 2px;
        background: var(--muted);
        animation: eq 1s ease-in-out infinite;
      }
      .bars span:nth-child(1) { height: 10px; animation-delay: 0s; }
      .bars span:nth-child(2) { height: 22px; animation-delay: 0.12s; }
      .bars span:nth-child(3) { height: 14px; animation-delay: 0.24s; }
      .bars span:nth-child(4) { height: 26px; animation-delay: 0.08s; }
      .bars span:nth-child(5) { height: 12px; animation-delay: 0.2s; }
      .bars.idle span { animation: none; opacity: 0.7; }
      @keyframes eq {
        0%, 100% { transform: scaleY(0.45); }
        50% { transform: scaleY(1); }
      }
      .shimmer {
        position: absolute;
        inset: 0;
        background: linear-gradient(110deg, transparent 25%, color-mix(in srgb, var(--text) 10%, transparent) 50%, transparent 75%);
        background-size: 200% 100%;
        animation: shine 1.6s linear infinite;
      }
      @keyframes shine {
        from { background-position: 200% 0; }
        to { background-position: -200% 0; }
      }
      audio { width: 100%; }
      .bar {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 6px 10px;
        padding-top: 8px;
        min-height: 22px;
      }
      .model {
        display: flex;
        align-items: center;
        gap: 6px;
        min-width: 0;
        font-weight: 600;
        font-size: 12px;
      }
      .model img, .glyph {
        width: 14px;
        height: 14px;
        border-radius: 3px;
        flex: none;
      }
      .glyph {
        display: grid;
        place-items: center;
        color: var(--muted);
        font-size: 9px;
      }
      .model span {
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .meta {
        display: flex;
        flex: 1 0 100%;
        align-items: center;
        gap: 6px 10px;
        min-width: 0;
      }
      .facts {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        min-width: 0;
        color: var(--muted);
        font-size: 11px;
        font-variant-numeric: tabular-nums;
      }
      .facts span + span::before {
        content: "·";
        margin: 0 6px;
        opacity: 0.55;
      }
      .prompt-drop {
        flex: 1 0 100%;
        min-width: 0;
      }
      .icon-btn {
        appearance: none;
        border: 0;
        background: transparent;
        color: var(--muted);
        padding: 2px;
        margin-left: auto;
        cursor: pointer;
        display: grid;
        place-items: center;
        border-radius: 4px;
        flex: none;
      }
      .icon-btn:hover { color: var(--text); }
      .icon-btn[hidden] { display: none; }
      .prompt-drop summary {
        cursor: pointer;
        color: var(--muted);
        font-size: 11px;
        list-style: none;
        user-select: none;
      }
      .prompt-drop summary::-webkit-details-marker { display: none; }
      .prompt-drop summary::after { content: " ▾"; }
      .prompt-drop[open] summary::after { content: " ▴"; }
      .prompt-drop p {
        margin: 6px 0 0;
        color: var(--muted);
        white-space: pre-wrap;
      }
      .error { color: var(--muted); }
      html.collapsed, html.collapsed body {
        height: 0 !important;
        overflow: hidden;
        margin: 0;
        padding: 0;
      }
      html.collapsed .card, html.collapsed .gallery { display: none; }
      .gallery {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
        gap: 8px;
      }
      .gallery .card { min-width: 0; }
    </style>
    <div id="single">
    <div class="card">
      <div class="stage" id="stage">
        <div class="shimmer" id="shimmer"></div>
        <span class="status" id="status">Generating…</span>
      </div>
      <div class="bar">
        <div class="meta">
          <div class="model" id="modelRow" hidden>
            <span id="iconSlot"><span class="glyph" id="glyph">◆</span></span>
            <span id="modelName"></span>
          </div>
          <div class="facts" id="chips"></div>
          <button type="button" class="icon-btn" id="finderBtn" hidden title="Show in Finder" aria-label="Show in Finder">
            <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
              <path fill="currentColor" d="M3.5 2.5h4v1h-4a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1v-4h1v4a2 2 0 0 1-2 2h-8a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2zm5.8.5h4.2V7h-1V4.2L7.85 8.85l-.7-.7L11.8 3.5H9.3z"/>
            </svg>
          </button>
        </div>
        <details class="prompt-drop" id="promptDrop" hidden>
          <summary>Prompt</summary>
          <p id="prompt"></p>
        </details>
      </div>
    </div>
    </div>
    <div class="gallery" id="gallery" hidden></div>
    <script>
    (() => {
      const single = document.getElementById("single");
      const gallery = document.getElementById("gallery");
      const stage = document.getElementById("stage");
      const status = document.getElementById("status");
      const shimmer = document.getElementById("shimmer");
      const modelRow = document.getElementById("modelRow");
      const modelName = document.getElementById("modelName");
      const iconSlot = document.getElementById("iconSlot");
      const promptEl = document.getElementById("prompt");
      const promptDrop = document.getElementById("promptDrop");
      const chips = document.getElementById("chips");
      const finderBtn = document.getElementById("finderBtn");
      const finderIcon = `<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path fill="currentColor" d="M3.5 2.5h4v1h-4a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1v-4h1v4a2 2 0 0 1-2 2h-8a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2zm5.8.5h4.2V7h-1V4.2L7.85 8.85l-.7-.7L11.8 3.5H9.3z"/></svg>`;
      let nextId = 1;
      const pending = new Map();
      let alive = true;
      let mediaRef = null;
      let previewUri = null;
      let kind = "image";
      let timelineId = null;
      let groupRole = "host";
      let groupMembers = [];
      let pollTimer = 0;
      let keepPolling = false;
      let objectUrl = null;
      let loadedPlayableRef = null;
      const objectUrls = new Map();
      let imageBurstUntil = 0;

      function post(payload) { window.parent.postMessage(payload, "*"); }
      function request(method, params) {
        const id = nextId++;
        return new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject });
          post({ jsonrpc: "2.0", id, method, params });
        });
      }
      function notify(method, params) { post({ jsonrpc: "2.0", method, params }); }
      function reportSize() {
        if (document.documentElement.classList.contains("collapsed")) {
          notify("ui/notifications/size-changed", { width: 0, height: 0 });
          return;
        }
        const rect = document.documentElement.getBoundingClientRect();
        notify("ui/notifications/size-changed", {
          width: Math.ceil(rect.width),
          height: Math.ceil(rect.height),
        });
      }
      function setAspectOn(el, value) {
        if (!el || typeof value !== "string" || !value.includes(":")) return;
        const [w, h] = value.split(":").map(Number);
        if (!w || !h) return;
        el.style.setProperty("--preview-aspect", `${w} / ${h}`);
        el.classList.toggle("portrait", h > w);
      }
      function setAspect(value) { setAspectOn(stage, value); }
      function formatDuration(seconds) {
        const n = Number(seconds);
        if (!n || n < 0) return null;
        if (n < 60) return `${Math.round(n)}s`;
        const m = Math.floor(n / 60);
        const s = Math.round(n % 60);
        return `${m}:${String(s).padStart(2, "0")}`;
      }
      function creditLabel(credits) {
        if (typeof credits !== "number" || !Number.isFinite(credits)) return null;
        if (credits === 1) return "1 credit";
        return `${credits} credits`;
      }
      function chipLabels(data) {
        const items = [];
        if (data.aspectRatio) items.push(data.aspectRatio);
        if (data.resolution) items.push(data.resolution);
        if ((data.kind || kind) !== "image") {
          const duration = formatDuration(data.duration);
          if (duration) items.push(duration);
        }
        const credits = creditLabel(data.credits);
        if (credits) items.push(credits);
        return items;
      }
      function makeChips(data) {
        return chipLabels(data).map((label) => {
          const chip = document.createElement("span");
          chip.textContent = label;
          return chip;
        });
      }
      function setPrompt(elDrop, elText, text) {
        const value = typeof text === "string" ? text.trim() : "";
        if (!elDrop || !elText) return;
        if (!value) {
          elDrop.hidden = true;
          elText.textContent = "";
          return;
        }
        elText.textContent = value;
        elDrop.hidden = false;
      }
      function revokeObjectUrl() {
        for (const url of objectUrls.values()) URL.revokeObjectURL(url);
        objectUrls.clear();
        objectUrl = null;
        loadedPlayableRef = null;
      }
      function blobUrlFromBase64(b64, mime, ref) {
        const prev = ref && objectUrls.get(ref);
        if (prev) URL.revokeObjectURL(prev);
        else if (!ref && objectUrl) URL.revokeObjectURL(objectUrl);
        const url = URL.createObjectURL(new Blob([base64ToBytes(b64)], { type: mime }));
        if (ref) objectUrls.set(ref, url);
        objectUrl = url;
        return url;
      }
      function setFinderVisible(visible) {
        if (finderBtn) finderBtn.hidden = !visible;
      }
      function syncActionButton() {
        if (!finderBtn) return;
        if (kind === "timeline") {
          finderBtn.title = "View in Palmier";
          finderBtn.setAttribute("aria-label", "View in Palmier");
          setFinderVisible(!!timelineId);
        } else {
          finderBtn.title = "Show in Finder";
          finderBtn.setAttribute("aria-label", "Show in Finder");
        }
      }
      async function revealInFinder(ref) {
        if (!ref) return;
        try {
          await request("tools/call", {
            name: "reveal_generation_media",
            arguments: { mediaRef: ref },
          });
        } catch {}
      }
      async function revealTimeline(id) {
        if (!id) return;
        try {
          await request("tools/call", {
            name: "reveal_timeline",
            arguments: { timelineId: id },
          });
        } catch {}
      }
      function makeFinderButton(ref) {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "icon-btn";
        btn.title = "Show in Finder";
        btn.setAttribute("aria-label", "Show in Finder");
        btn.innerHTML = finderIcon;
        btn.addEventListener("click", (event) => {
          event.preventDefault();
          revealInFinder(ref);
        });
        return btn;
      }
      function makePalmierButton(id) {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "icon-btn";
        btn.title = "View in Palmier";
        btn.setAttribute("aria-label", "View in Palmier");
        btn.innerHTML = finderIcon;
        btn.addEventListener("click", (event) => {
          event.preventDefault();
          revealTimeline(id);
        });
        return btn;
      }
      function collapse() {
        stopPolling();
        document.documentElement.classList.add("collapsed");
        single.hidden = true;
        gallery.hidden = true;
        reportSize();
      }
      function clearMedia() {
        for (const node of [...stage.querySelectorAll("img, video, audio, .badge, .play, .bars")]) {
          node.remove();
        }
      }
      function showGenerating(phase) {
        if (kind === "timeline") syncActionButton();
        else setFinderVisible(false);
        stage.classList.remove("ready");
        shimmer.hidden = false;
        status.hidden = false;
        status.textContent = phase || (kind === "timeline" ? "Rendering…" : "Generating…");
        status.classList.remove("error");
        if (!status.isConnected) stage.append(status);
        if (kind === "audio") {
          stage.classList.add("audio");
          if (!stage.querySelector(".bars")) {
            const bars = document.createElement("div");
            bars.className = "bars";
            bars.innerHTML = "<span></span><span></span><span></span><span></span><span></span>";
            stage.append(bars);
          }
        } else {
          stage.classList.remove("audio");
        }
        reportSize();
      }
      function showError(message) {
        if (!isBurstKind(kind) && kind !== "timeline") stopPolling();
        setFinderVisible(false);
        stage.classList.remove("ready");
        shimmer.hidden = true;
        clearMedia();
        status.hidden = false;
        status.classList.add("error");
        status.textContent = message || "Generation failed";
        if (!status.isConnected) stage.append(status);
        reportSize();
      }
      function applyMeta(data) {
        if (!data) return;
        if (data.kind) kind = data.kind;
        if (data.timelineId) timelineId = data.timelineId;
        if (data.aspectRatio) setAspect(data.aspectRatio);
        if (kind === "timeline") {
          modelName.textContent = data.timelineName || data.name || "";
          modelRow.hidden = !modelName.textContent;
          iconSlot.replaceChildren();
          iconSlot.hidden = true;
          setPrompt(promptDrop, promptEl, "");
          chips.replaceChildren();
        } else {
          iconSlot.hidden = false;
          if (data.model) {
            modelName.textContent = data.model;
            modelRow.hidden = false;
          }
          if (data.modelIconKey) loadIcon(data.modelIconKey, iconSlot);
          setPrompt(promptDrop, promptEl, data.prompt);
          chips.replaceChildren(...makeChips(data));
        }
        syncActionButton();
        if (kind === "audio") stage.classList.add("audio");
        reportSize();
      }
      async function loadIcon(key, slot) {
        if (!slot) return;
        try {
          const result = await request("resources/read", { uri: "palmier://model-icon/" + key });
          const blob = result && result.contents && result.contents[0];
          let src = null;
          if (blob && blob.blob) src = `data:${blob.mimeType || "image/png"};base64,${blob.blob}`;
          else if (blob && blob.text && blob.text.startsWith("data:")) src = blob.text;
          if (!src) return;
          const img = document.createElement("img");
          img.alt = "";
          img.src = src;
          slot.replaceChildren(img);
        } catch {}
      }
      function showImage(src) {
        shimmer.hidden = true;
        if (status.isConnected) status.remove();
        clearMedia();
        const img = document.createElement("img");
        img.alt = kind === "video" ? "Generated video" : "Generated image";
        img.onload = reportSize;
        img.src = src;
        stage.append(img);
        stage.classList.add("ready");
        reportSize();
      }
      function showVideo(src, poster) {
        shimmer.hidden = true;
        if (status.isConnected) status.remove();
        let video = stage.querySelector("video");
        if (!video) {
          clearMedia();
          video = document.createElement("video");
          video.controls = true;
          video.playsInline = true;
          video.preload = "metadata";
          video.onloadedmetadata = () => {
            if (video.videoWidth && video.videoHeight) {
              video.width = video.videoWidth;
              video.height = video.videoHeight;
              setAspectOn(stage, `${video.videoWidth}:${video.videoHeight}`);
            }
            reportSize();
          };
          stage.append(video);
        }
        if (poster && video.poster !== poster) video.poster = poster;
        if (src && video.getAttribute("src") !== src) video.src = src;
        stage.classList.add("ready");
        reportSize();
      }
      function showAudio(src) {
        shimmer.hidden = true;
        if (status.isConnected) status.remove();
        clearMedia();
        stage.classList.add("audio", "ready");
        if (src) {
          const audio = document.createElement("audio");
          audio.controls = true;
          audio.src = src;
          audio.onerror = () => showAudio(null);
          stage.append(audio);
        } else {
          const bars = document.createElement("div");
          bars.className = "bars idle";
          bars.innerHTML = "<span></span><span></span><span></span><span></span><span></span>";
          stage.append(bars);
          const ready = document.createElement("span");
          ready.className = "status";
          ready.textContent = "Ready in Palmier";
          stage.append(ready);
        }
        reportSize();
      }
      function previewSrc(payload) {
        const preview = payload && payload.preview;
        if (preview && preview.data) {
          return `data:${preview.mimeType || "image/jpeg"};base64,${preview.data}`;
        }
        return null;
      }
      function audioSrc(payload) {
        if (payload && payload.mediaUrl) return payload.mediaUrl;
        const audio = payload && payload.audio;
        if (audio && audio.data) {
          return `data:${audio.mimeType || "audio/mpeg"};base64,${audio.data}`;
        }
        return null;
      }
      function base64ToBytes(b64) {
        const bin = atob(b64);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        return bytes;
      }
      async function loadPlayableUrl(payload) {
        const mime = (payload && payload.mimeType) || (kind === "audio" ? "audio/mpeg" : "video/mp4");
        const ref = (payload && payload.mediaRef) || mediaRef;
        if (objectUrls.has(ref)) return objectUrls.get(ref);
        if (objectUrl && loadedPlayableRef === ref) return objectUrl;
        const inline = payload && payload.media;
        if (inline && inline.data) {
          const url = blobUrlFromBase64(inline.data, inline.mimeType || mime, ref);
          loadedPlayableRef = ref;
          return url;
        }
        if (ref) {
          try {
            const full = parsePayload(await request("tools/call", {
              name: "get_generation_preview",
              arguments: { mediaRef: ref, includeMedia: true },
            }));
            if (full && full.media && full.media.data) {
              const url = blobUrlFromBase64(full.media.data, full.media.mimeType || mime, ref);
              loadedPlayableRef = ref;
              return url;
            }
          } catch {}
        }
        const uri = payload && payload.mediaResourceUri;
        if (uri) {
          try {
            const result = await request("resources/read", { uri });
            const block = result && result.contents && result.contents[0];
            if (block && block.blob) {
              const url = blobUrlFromBase64(block.blob, block.mimeType || mime, ref);
              loadedPlayableRef = ref;
              return url;
            }
          } catch {}
        }
        return (payload && payload.mediaUrl) || null;
      }
      async function applyReady(payload) {
        applyMeta(payload);
        setFinderVisible(kind === "timeline" ? !!timelineId : !!((payload && payload.mediaRef) || mediaRef));
        if (kind === "audio") {
          showAudio(await loadPlayableUrl(payload) || audioSrc(payload));
          return;
        }
        if (kind === "video" || kind === "timeline") {
          const poster = previewSrc(payload);
          showVideo(null, poster);
          const src = await loadPlayableUrl(payload);
          if (src) showVideo(src, poster);
          return;
        }
        const src = previewSrc(payload);
        if (src) showImage(src);
        else showGenerating("Ready in Palmier");
        shimmer.hidden = true;
      }
      function parsePayload(result) {
        if (!result) return null;
        if (result.structuredContent && typeof result.structuredContent === "object") {
          return result.structuredContent;
        }
        const blocks = result.content || result.contents || [];
        for (const block of blocks) {
          const text = block && (block.text || (block.type === "text" && block.text));
          if (typeof text !== "string") continue;
          const trimmed = text.trim();
          if (!trimmed.startsWith("{")) continue;
          try { return JSON.parse(trimmed); } catch {}
        }
        if (typeof result.text === "string" && result.text.trim().startsWith("{")) {
          try { return JSON.parse(result.text); } catch {}
        }
        return null;
      }
      function rememberGroup(payload) {
        if (Array.isArray(payload.groupMembers) && payload.groupMembers.length) {
          groupMembers = payload.groupMembers;
        }
        if (groupRole === "host" && mediaRef && payload.groupRole === "member") {
          return;
        }
        if (payload.groupRole) groupRole = payload.groupRole;
      }
      function isBurstKind(k) {
        return k === "image" || k === "video";
      }
      function previewMembers(payload) {
        const members = Array.isArray(payload.groupMembers) && payload.groupMembers.length
          ? payload.groupMembers
          : groupMembers;
        const k = payload.kind || kind;
        if ((isBurstKind(k) || k === "timeline") && members.length > 1) return members;
        return null;
      }
      async function fillTileStage(stageEl, data) {
        stageEl.replaceChildren();
        setAspectOn(stageEl, data.aspectRatio);
        if (data.status === "failed") {
          const err = document.createElement("span");
          err.className = "status error";
          err.textContent = data.error || "Generation failed";
          stageEl.append(err);
          return;
        }
        if (data.status === "ready" && (data.kind === "timeline" || data.kind === "video")) {
          const src = await loadPlayableUrl(data);
          if (src) {
            const video = document.createElement("video");
            video.controls = true;
            video.playsInline = true;
            video.preload = "metadata";
            video.src = src;
            video.onloadedmetadata = () => {
              if (video.videoWidth && video.videoHeight) {
                setAspectOn(stageEl, `${video.videoWidth}:${video.videoHeight}`);
              }
              reportSize();
            };
            stageEl.append(video);
            stageEl.classList.add("ready");
            return;
          }
        }
        const src = previewSrc(data);
        if (data.status === "ready" && src) {
          const img = document.createElement("img");
          img.alt = "Generated image";
          img.onload = reportSize;
          img.src = src;
          stageEl.append(img);
          stageEl.classList.add("ready");
          return;
        }
        stageEl.classList.remove("ready");
        const shine = document.createElement("div");
        shine.className = "shimmer";
        stageEl.append(shine);
        const label = document.createElement("span");
        label.className = "status";
        label.textContent = data.phase === "downloading" ? "Downloading…"
          : data.phase === "preparing" ? "Preparing…"
          : data.phase === "rendering" ? "Rendering…"
          : data.kind === "timeline" ? "Rendering…"
          : "Generating…";
        stageEl.append(label);
      }
      async function makeTile(data) {
        const card = document.createElement("div");
        card.className = "card";
        const stageEl = document.createElement("div");
        stageEl.className = "stage";
        await fillTileStage(stageEl, data);
        const bar = document.createElement("div");
        bar.className = "bar";
        const model = document.createElement("div");
        model.className = "model";
        const name = document.createElement("span");
        const meta = document.createElement("div");
        meta.className = "meta";
        if (data.kind === "timeline") {
          name.textContent = data.timelineName || data.name || "";
          model.append(name);
          meta.append(model);
          if (data.timelineId) meta.append(makePalmierButton(data.timelineId));
          bar.append(meta);
        } else {
          const slot = document.createElement("span");
          const icon = document.createElement("span");
          icon.className = "glyph";
          icon.textContent = "◆";
          slot.append(icon);
          name.textContent = data.model || "";
          model.append(slot, name);
          if (data.modelIconKey) loadIcon(data.modelIconKey, slot);
          const facts = document.createElement("div");
          facts.className = "facts";
          facts.append(...makeChips(data));
          const drop = document.createElement("details");
          drop.className = "prompt-drop";
          const summary = document.createElement("summary");
          summary.textContent = "Prompt";
          const body = document.createElement("p");
          drop.append(summary, body);
          drop.addEventListener("toggle", reportSize);
          setPrompt(drop, body, data.prompt);
          meta.append(model, facts);
          if (data.status === "ready" && data.mediaRef) {
            meta.append(makeFinderButton(data.mediaRef));
          }
          bar.append(meta, drop);
        }
        card.append(stageEl, bar);
        return card;
      }
      async function renderGallery(refs) {
        document.documentElement.classList.remove("collapsed");
        const payloads = [];
        for (const ref of refs) {
          payloads.push(await loadPreview(ref));
        }
        const cards = [];
        for (let index = 0; index < payloads.length; index++) {
          cards.push(await makeTile(payloads[index] || {
            status: "generating",
            mediaRef: refs[index],
            kind: kind,
          }));
        }
        gallery.replaceChildren(...cards);
        gallery.hidden = false;
        single.hidden = true;
        reportSize();
        return payloads.some((item) => !item || item.status === "generating");
      }
      async function loadPreview(ref) {
        try {
          return parsePayload(await request("tools/call", {
            name: "get_generation_preview",
            arguments: { mediaRef: ref },
          }));
        } catch {
          return null;
        }
      }
      async function fetchPreview() {
        if (!mediaRef || groupRole === "member") return;
        const payload = await loadPreview(mediaRef);
        if (!payload) return;
        rememberGroup(payload);
        if (groupRole === "member" && previewMembers(payload)) {
          collapse();
          return;
        }
        const members = previewMembers(payload);
        if (members) {
          groupMembers = members;
          let pendingWork = true;
          try {
            pendingWork = await renderGallery(members);
          } catch {
            single.hidden = false;
            gallery.hidden = true;
            reportSize();
          }
          if (pendingWork) {
            imageBurstUntil = 0;
          } else if (!imageBurstUntil) {
            imageBurstUntil = Date.now() + 8000;
          } else if (Date.now() >= imageBurstUntil) {
            stopPolling();
          }
          return;
        }
        applyMeta(payload);
        if (payload.status === "ready") {
          await applyReady(payload);
          if (!isBurstKind(kind)) {
            stopPolling();
          } else if (!imageBurstUntil) {
            imageBurstUntil = Date.now() + 8000;
          } else if (Date.now() >= imageBurstUntil) {
            stopPolling();
          }
        } else if (payload.status === "failed") {
          showError(payload.error);
        } else {
          imageBurstUntil = 0;
          const phase = payload.phase === "downloading" ? "Downloading…"
            : payload.phase === "preparing" ? "Preparing…"
            : payload.phase === "rendering" ? "Rendering…"
            : "Generating…";
          showGenerating(phase);
        }
      }
      function stopPolling() {
        keepPolling = false;
        if (pollTimer) {
          clearTimeout(pollTimer);
          pollTimer = 0;
        }
      }
      function startPolling() {
        stopPolling();
        keepPolling = true;
        let delay = 800;
        const tick = async () => {
          if (!alive || !keepPolling || !mediaRef || groupRole === "member") return;
          await fetchPreview();
          if (!alive || !keepPolling || !mediaRef || groupRole === "member") return;
          delay = Math.min(delay + 400, 2000);
          pollTimer = setTimeout(tick, delay);
        };
        pollTimer = setTimeout(tick, 400);
      }
      function showPlaceholder(args) {
        applyMeta({
          kind: kind,
          prompt: args && args.prompt,
          aspectRatio: args && args.aspectRatio,
          resolution: args && args.resolution,
          duration: args && args.duration,
          model: args && args.model,
        });
        showGenerating();
      }
      async function showResult(result) {
        if (!result) return;
        if (result.isError) {
          const text = (result.content || []).find((block) => block.type === "text");
          showError(text && text.text);
          return;
        }
        const payload = parsePayload(result);
        if (payload) {
          rememberGroup(payload);
          if (groupRole === "member" && previewMembers(payload)) {
            collapse();
            return;
          }
          if (!mediaRef && payload.mediaRef) mediaRef = payload.mediaRef;
          if (!previewUri && payload.previewUri) previewUri = payload.previewUri;
          applyMeta(payload);
          if (previewMembers(payload)) {
            startPolling();
            fetchPreview();
            return;
          }
          if (payload.status === "ready") {
            await applyReady(payload);
            if (isBurstKind(kind)) startPolling();
            return;
          }
          if (payload.status === "failed") {
            showError(payload.error);
            return;
          }
          showGenerating();
          startPolling();
          return;
        }
        const blocks = result.content || [];
        for (const block of blocks) {
          if (block && block.type === "image" && block.data) {
            showImage(`data:${block.mimeType || "image/jpeg"};base64,${block.data}`);
            return;
          }
        }
        showGenerating();
      }
      function handleHostNotification(msg) {
        const uri = msg.params && msg.params.uri;
        if (!uri || groupRole === "member") return;
        if (previewUri && uri === previewUri) fetchPreview();
        else if (mediaRef && uri.endsWith(mediaRef)) fetchPreview();
        else if (groupMembers.some((ref) => uri.endsWith(ref))) fetchPreview();
      }

      window.addEventListener("message", (event) => {
        const msg = event.data;
        if (!msg || msg.jsonrpc !== "2.0") return;
        if (Object.prototype.hasOwnProperty.call(msg, "id") && pending.has(msg.id)) {
          const waiter = pending.get(msg.id);
          pending.delete(msg.id);
          if (msg.error) waiter.reject(msg.error);
          else waiter.resolve(msg.result);
          return;
        }
        if (msg.method === "ping") {
          post({ jsonrpc: "2.0", id: msg.id, result: {} });
          return;
        }
        if (msg.method === "ui/resource-teardown") {
          alive = false;
          stopPolling();
          revokeObjectUrl();
          post({ jsonrpc: "2.0", id: msg.id, result: {} });
          return;
        }
        if (msg.method === "ui/notifications/tool-input") {
          showPlaceholder(msg.params && msg.params.arguments);
          return;
        }
        if (msg.method === "ui/notifications/tool-result") {
          showResult(msg.params);
          return;
        }
        if (msg.method === "ui/notifications/tool-cancelled") {
          showError("Generation cancelled");
          return;
        }
        if (msg.method === "notifications/resources/updated"
            || msg.method === "ui/notifications/resources/updated") {
          handleHostNotification(msg);
        }
      });

      promptDrop.addEventListener("toggle", reportSize);
      finderBtn.addEventListener("click", (event) => {
        event.preventDefault();
        if (kind === "timeline") revealTimeline(timelineId);
        else revealInFinder(mediaRef);
      });
      new ResizeObserver(reportSize).observe(document.documentElement);

      (async () => {
        await request("ui/initialize", {
          protocolVersion: "2026-01-26",
          appInfo: { name: "MCPPreviewApp", version: "1.6.1" },
          appCapabilities: { availableDisplayModes: ["inline"] },
        });
        notify("ui/notifications/initialized", {});
        reportSize();
      })();
    })();
    </script>
    """#
}
