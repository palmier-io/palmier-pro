import Foundation
import MCP

enum MCPPreviewApp {
    static let resourceURI = "ui://palmier/MCPPreviewApp.html"
    static let mimeType = "text/html;profile=mcp-app"
    static let previewMaxPixelSize = 512
    static let html = htmlSource

    static var toolMeta: Metadata {
        Metadata(additionalFields: [
            "ui": .object(["resourceUri": .string(resourceURI)]),
        ])
    }

    static var resourceMeta: Metadata {
        Metadata(additionalFields: [
            "ui": .object(["prefersBorder": .bool(false)]),
        ])
    }

    static var resource: Resource {
        Resource(
            name: "Generated Image Preview",
            uri: resourceURI,
            description: "Inline preview for generate_image",
            mimeType: mimeType,
            _meta: resourceMeta
        )
    }
}

extension MCPPreviewApp {
    private static let htmlSource = #"""
    <!doctype html>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Generated image</title>
    <style>
      :root {
        color-scheme: light dark;
        --color-background-primary: light-dark(#f4f4f5, #18181b);
        --color-text-secondary: light-dark(#71717a, #a1a1aa);
      }
      html, body {
        margin: 0;
        background: var(--color-background-primary);
        color: var(--color-text-secondary);
        font: 13px/1.4 system-ui, sans-serif;
      }
      #frame {
        width: 100%;
        aspect-ratio: var(--preview-aspect, 1);
        display: grid;
        place-items: center;
        overflow: hidden;
      }
      #frame img {
        width: 100%;
        height: 100%;
        object-fit: contain;
        display: block;
      }
      #frame.ready {
        aspect-ratio: auto;
      }
      #frame.ready img {
        height: auto;
      }
      #status { padding: 24px 16px; }
    </style>
    <div id="frame"><span id="status">Generating…</span></div>
    <script>
    (() => {
      const frame = document.getElementById("frame");
      const status = document.getElementById("status");
      let nextId = 1;
      const pending = new Map();

      function post(payload) {
        window.parent.postMessage(payload, "*");
      }
      function request(method, params) {
        const id = nextId++;
        return new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject });
          post({ jsonrpc: "2.0", id, method, params });
        });
      }
      function notify(method, params) {
        post({ jsonrpc: "2.0", method, params });
      }
      function reportSize() {
        const rect = document.documentElement.getBoundingClientRect();
        notify("ui/notifications/size-changed", {
          width: Math.ceil(rect.width),
          height: Math.ceil(rect.height),
        });
      }
      function setAspect(value) {
        if (typeof value !== "string") return;
        const parts = value.split(":");
        if (parts.length !== 2) return;
        const w = Number(parts[0]);
        const h = Number(parts[1]);
        if (!w || !h) return;
        frame.style.setProperty("--preview-aspect", `${w} / ${h}`);
        reportSize();
      }
      function showPlaceholder(args) {
        setAspect(args && args.aspectRatio);
        status.textContent = "Generating…";
        frame.classList.remove("ready");
        const img = frame.querySelector("img");
        if (img) img.remove();
        if (!status.isConnected) frame.append(status);
        reportSize();
      }
      function showImage(src) {
        status.remove();
        let img = frame.querySelector("img");
        if (!img) {
          img = document.createElement("img");
          img.alt = "Generated image";
          frame.append(img);
        }
        img.onload = reportSize;
        img.src = src;
        frame.classList.add("ready");
        reportSize();
      }
      function showError(message) {
        status.textContent = message || "Generation failed";
        frame.classList.remove("ready");
        const img = frame.querySelector("img");
        if (img) img.remove();
        if (!status.isConnected) frame.append(status);
        reportSize();
      }
      function imageSrc(result) {
        const blocks = result && result.content;
        if (!Array.isArray(blocks)) return null;
        for (const block of blocks) {
          if (block && block.type === "image" && block.data) {
            return `data:${block.mimeType || "image/jpeg"};base64,${block.data}`;
          }
        }
        return null;
      }
      function showResult(result) {
        if (!result) return;
        if (result.isError) {
          const text = (result.content || []).find((block) => block.type === "text");
          showError(text && text.text);
          return;
        }
        const src = imageSrc(result);
        if (src) showImage(src);
        else showPlaceholder();
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
        }
      });

      new ResizeObserver(reportSize).observe(document.documentElement);

      (async () => {
        await request("ui/initialize", {
          protocolVersion: "2026-01-26",
          appInfo: { name: "MCPPreviewApp", version: "1.0.0" },
          appCapabilities: { availableDisplayModes: ["inline"] },
        });
        notify("ui/notifications/initialized", {});
        reportSize();
      })();
    })();
    </script>
    """#
}
