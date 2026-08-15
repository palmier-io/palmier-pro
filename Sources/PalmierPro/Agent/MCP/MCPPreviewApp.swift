import Foundation
import MCP

enum MCPPreviewApp {
    static let resourceURI = "ui://palmier/preview"
    static let mimeType = "text/html;profile=mcp-app"
    static let loopbackOrigin = "http://127.0.0.1:\(MCPService.port)"
    static let maxAssets = 12

    static var toolMeta: Metadata {
        Metadata(additionalFields: [
            "ui": .object([
                "resourceUri": .string(resourceURI),
                "csp": cspValue,
            ]),
            "ui/resourceUri": .string(resourceURI),
        ])
    }

    static var resourceMeta: Metadata {
        Metadata(additionalFields: [
            "ui": .object(["csp": cspValue]),
        ])
    }

    static func previewURL(token: String, port: UInt16 = MCPService.port) -> String {
        "http://127.0.0.1:\(port)/preview/\(token)"
    }

    static func mimeType(for url: URL, type: ClipType) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "webm": "video/webm"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "m4a", "aac": "audio/mp4"
        case "aiff", "aif": "audio/aiff"
        case "caf": "audio/x-caf"
        case "flac": "audio/flac"
        default:
            switch type {
            case .video: "video/mp4"
            case .image: "image/jpeg"
            case .audio: "audio/mpeg"
            default: "application/octet-stream"
            }
        }
    }

    static let html = #"""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  html, body { margin: 0; background: #111; color: #eee; font: 12px/1.35 -apple-system, system-ui, sans-serif; }
  .grid { display: grid; gap: 10px; padding: 8px; justify-items: center; }
  .grid.one { grid-template-columns: 1fr; }
  .grid.many { grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); }
  .card { display: flex; flex-direction: column; align-items: center; min-width: 0; width: 100%; }
  .card video, .card img { display: block; background: #000; border-radius: 6px; }
  .card.portrait video, .card.portrait img {
    width: auto; height: auto;
    max-width: min(100%, 360px);
    max-height: 640px;
  }
  .card.landscape video, .card.landscape img,
  .card.unknown video, .card.unknown img {
    width: 100%; height: auto;
    max-height: 360px;
    object-fit: contain;
  }
  .card audio { width: 100%; }
  .label { margin-top: 6px; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; opacity: 0.65; }
  .meta { margin-top: 6px; max-width: min(100%, 420px); opacity: 0.75; }
  .meta .model { opacity: 0.85; }
  .meta .prompt { margin-top: 4px; white-space: pre-wrap; }
  .ph {
    width: min(100%, 360px); min-height: 160px; border-radius: 6px;
    background: #1c1c1c; display: flex; align-items: center; justify-content: center;
    text-align: center; padding: 16px; opacity: 0.8;
  }
  .msg { padding: 16px; opacity: 0.7; }
</style>
</head>
<body>
<div id="g" class="grid one"></div>
<div id="m" class="msg">Loading preview…</div>
<script>
(function () {
  var nextId = 1;
  var pending = {};
  var sizeTimer = 0;
  function send(msg) { window.parent.postMessage(msg, "*"); }
  function rpc(method, params) {
    var id = nextId++;
    return new Promise(function (resolve) {
      pending[id] = resolve;
      send({ jsonrpc: "2.0", id: id, method: method, params: params || {} });
    });
  }
  function reportSize() {
    clearTimeout(sizeTimer);
    sizeTimer = setTimeout(function () {
      var h = Math.ceil(document.body.scrollHeight || 0);
      var w = Math.ceil(document.body.scrollWidth || 0);
      if (h < 1) return;
      send({ jsonrpc: "2.0", method: "ui/notifications/size-changed", params: { width: w, height: h } });
    }, 50);
  }
  function orientation(item, el) {
    var w = item.width || (el && (el.videoWidth || el.naturalWidth)) || 0;
    var h = item.height || (el && (el.videoHeight || el.naturalHeight)) || 0;
    if (w > 0 && h > w) return "portrait";
    if (w > 0 && h > 0) return "landscape";
    return "unknown";
  }
  function applyAspect(card, item, el) {
    card.classList.remove("portrait", "landscape", "unknown");
    card.classList.add(orientation(item, el));
    var w = item.width || (el && (el.videoWidth || el.naturalWidth)) || 0;
    var h = item.height || (el && (el.videoHeight || el.naturalHeight)) || 0;
    if (w > 0 && h > 0 && el) el.style.aspectRatio = w + " / " + h;
    reportSize();
  }
  function itemsFrom(sc) {
    if (sc.items && sc.items.length) return sc.items;
    if (sc.videoUrl) return [{ type: "video", url: sc.videoUrl, name: sc.name, width: sc.width, height: sc.height }];
    if (sc.imageUrl) return [{ type: "image", url: sc.imageUrl, name: sc.name, width: sc.width, height: sc.height }];
    if (sc.audioUrl) return [{ type: "audio", url: sc.audioUrl, name: sc.name }];
    return [];
  }
  function render(sc) {
    if (!sc) return;
    var items = itemsFrom(sc);
    var grid = document.getElementById("g");
    var msg = document.getElementById("m");
    grid.innerHTML = "";
    if (!items.length) {
      msg.style.display = "block";
      msg.textContent = sc.message || "No preview.";
      reportSize();
      return;
    }
    msg.style.display = "none";
    grid.className = "grid " + (items.length === 1 ? "one" : "many");
    items.forEach(function (item) {
      var card = document.createElement("div");
      card.className = "card " + orientation(item, null);
      var gen = item.generation || {};
      if (item.url && item.type === "video") {
        var v = document.createElement("video");
        v.controls = true;
        v.setAttribute("playsinline", "");
        v.src = item.url;
        v.addEventListener("loadedmetadata", function () { applyAspect(card, item, v); });
        card.appendChild(v);
        applyAspect(card, item, v);
      } else if (item.url && item.type === "image") {
        var i = document.createElement("img");
        i.alt = item.name || "";
        i.src = item.url;
        i.addEventListener("load", function () { applyAspect(card, item, i); });
        card.appendChild(i);
        applyAspect(card, item, i);
      } else if (item.url && item.type === "audio") {
        var a = document.createElement("audio");
        a.controls = true;
        a.src = item.url;
        a.addEventListener("loadedmetadata", reportSize);
        card.appendChild(a);
      } else {
        var ph = document.createElement("div");
        ph.className = "ph";
        ph.textContent = gen.status ? gen.status : "Waiting for media…";
        card.appendChild(ph);
      }
      if (item.name) {
        var label = document.createElement("div");
        label.className = "label";
        label.textContent = item.name;
        card.appendChild(label);
      }
      if (gen.model || gen.prompt) {
        var meta = document.createElement("div");
        meta.className = "meta";
        if (gen.model) {
          var model = document.createElement("div");
          model.className = "model";
          model.textContent = gen.aspectRatio ? gen.model + " · " + gen.aspectRatio : gen.model;
          meta.appendChild(model);
        }
        if (gen.prompt) {
          var prompt = document.createElement("div");
          prompt.className = "prompt";
          prompt.textContent = gen.prompt;
          meta.appendChild(prompt);
        }
        card.appendChild(meta);
      }
      grid.appendChild(card);
    });
    reportSize();
  }
  window.addEventListener("message", function (event) {
    var msg = event.data;
    if (!msg || msg.jsonrpc !== "2.0") return;
    if (msg.id != null && pending[msg.id]) {
      pending[msg.id](msg);
      delete pending[msg.id];
      return;
    }
    if (msg.method === "ui/notifications/tool-result" || msg.method === "ui/notifications/tool-input") {
      var params = msg.params || {};
      render(params.structuredContent || params.content);
    }
  });
  rpc("ui/initialize", {
    protocolVersion: "2026-01-26",
    appInfo: { name: "palmier-preview", version: "0.1.0" },
    appCapabilities: {}
  }).then(function (res) {
    send({ jsonrpc: "2.0", method: "ui/notifications/initialized" });
    var result = (res && res.result) || {};
    render(result.structuredContent);
  });
})();
</script>
</body>
</html>
"""#

    private static var cspValue: Value {
        .object([
            "resourceDomains": .array([.string(loopbackOrigin)]),
        ])
    }
}
