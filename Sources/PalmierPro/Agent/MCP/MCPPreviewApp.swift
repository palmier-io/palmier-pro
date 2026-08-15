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

    static func eventsURL(token: String, port: UInt16 = MCPService.port) -> String {
        previewURL(token: token, port: port) + "/events"
    }

    static func blobURL(token: String, port: UInt16 = MCPService.port) -> String {
        "http://127.0.0.1:\(port)/preview/blob/\(token)"
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
  .actions { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; justify-content: center; }
  .actions button, .bar button {
    appearance: none; border: 1px solid #444; background: #1c1c1c; color: #eee;
    border-radius: 6px; padding: 5px 10px; font: inherit; cursor: pointer;
  }
  .actions button:disabled, .bar button:disabled { opacity: 0.4; cursor: default; }
  .bar { display: flex; gap: 8px; align-items: center; padding: 0 8px 8px; flex-wrap: wrap; }
  .strip { display: flex; gap: 6px; overflow-x: auto; padding: 8px; width: 100%; box-sizing: border-box; }
  .strip img { height: 88px; width: auto; border-radius: 4px; background: #000; cursor: pointer; opacity: 0.7; }
  .strip img.on { opacity: 1; outline: 1px solid #888; }
  .stage { display: flex; justify-content: center; padding: 0 8px; }
  .stage img { max-width: 100%; max-height: 360px; border-radius: 6px; background: #000; }
  .note { padding: 0 8px 8px; opacity: 0.65; }
  .msg { padding: 16px; opacity: 0.7; }
  .status { padding: 0 8px 8px; min-height: 1em; opacity: 0.8; }
</style>
</head>
<body>
<div id="root"></div>
<div id="m" class="msg">Loading preview…</div>
<script>
(function () {
  var nextId = 1;
  var pending = {};
  var sizeTimer = 0;
  var playTimer = 0;
  var streams = [];
  function send(msg) { window.parent.postMessage(msg, "*"); }
  function rpc(method, params) {
    var id = nextId++;
    return new Promise(function (resolve, reject) {
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
  function setStatus(text) {
    var el = document.getElementById("status");
    if (el) el.textContent = text || "";
    reportSize();
  }
  function originOf(sc) {
    var first = (sc.items && sc.items[0]) || {};
    var url = first.eventsUrl || first.url || (sc.frames && sc.frames[0] && sc.frames[0].url) || "";
    try { return new URL(url).origin; } catch (e) { return ""; }
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
    if (sc.videoUrl) return [{ type: "video", url: sc.videoUrl, name: sc.name, width: sc.width, height: sc.height, mediaRef: sc.mediaRef, eventsUrl: sc.eventsUrl }];
    if (sc.imageUrl) return [{ type: "image", url: sc.imageUrl, name: sc.name, width: sc.width, height: sc.height, mediaRef: sc.mediaRef, eventsUrl: sc.eventsUrl }];
    if (sc.audioUrl) return [{ type: "audio", url: sc.audioUrl, name: sc.name, mediaRef: sc.mediaRef, eventsUrl: sc.eventsUrl }];
    return [];
  }
  function closeStreams() {
    streams.forEach(function (es) { try { es.close(); } catch (e) {} });
    streams = [];
    clearInterval(playTimer);
    playTimer = 0;
  }
  function watch(item, onReady) {
    if (!item.eventsUrl || item.url) return;
    var es = new EventSource(item.eventsUrl);
    streams.push(es);
    es.onmessage = function (ev) {
      try {
        var data = JSON.parse(ev.data);
        if (data.url) {
          item.url = data.url + (data.url.indexOf("?") >= 0 ? "&" : "?") + "t=" + Date.now();
          if (data.width) item.width = data.width;
          if (data.height) item.height = data.height;
          if (data.type) item.type = data.type;
          if (item.generation) item.generation.status = null;
          es.close();
          onReady();
        } else if (data.status && data.status.indexOf("failed") === 0) {
          item.generation = item.generation || {};
          item.generation.status = data.message || data.status;
          onReady();
        }
      } catch (e) {}
    };
  }
  function textOf(result) {
    var content = (result && result.content) || [];
    for (var i = 0; i < content.length; i++) {
      if (content[i] && content[i].text) return content[i].text;
    }
    return "";
  }
  function callTool(name, arguments) {
    return rpc("tools/call", { name: name, arguments: arguments }).then(function (res) {
      if (res && res.error) throw new Error(res.error.message || "Tool failed");
      var result = (res && res.result) || res || {};
      if (result.isError) throw new Error(textOf(result) || "Tool failed");
      return result;
    });
  }
  function bindAction(button, run) {
    button.addEventListener("click", function () {
      button.disabled = true;
      Promise.resolve(run()).then(function () {
        button.disabled = false;
      }).catch(function (err) {
        button.disabled = false;
        setStatus(err && err.message ? err.message : String(err));
      });
    });
  }
  function actionBar(item, sc) {
    var row = document.createElement("div");
    row.className = "actions";
    var origin = originOf(sc);
    if (item.canPlace !== false && item.mediaRef) {
      var place = document.createElement("button");
      place.textContent = "Place";
      bindAction(place, function () {
        return fetch(origin + "/preview/context").then(function (r) { return r.json(); }).then(function (ctx) {
          return callTool("add_clips", { entries: [{ mediaRef: item.mediaRef, startFrame: ctx.playheadFrame || 0 }] });
        }).then(function () { setStatus("Placed on the timeline."); });
      });
      row.appendChild(place);
    }
    if (item.canKeep && (item.clipId || sc.clipId) && item.mediaRef) {
      var keep = document.createElement("button");
      keep.textContent = "Keep";
      bindAction(keep, function () {
        return callTool("swap_clip_media", { clipId: item.clipId || sc.clipId, mediaRef: item.mediaRef })
          .then(function () { setStatus("Kept on the clip."); });
      });
      row.appendChild(keep);
    }
    if (item.canUpscale && item.mediaRef) {
      var up = document.createElement("button");
      up.textContent = "Upscale";
      bindAction(up, function () {
        return callTool("upscale_media", { mediaRef: item.mediaRef })
          .then(function () { setStatus("Upscale started."); });
      });
      row.appendChild(up);
    }
    if (item.canOpen !== false && item.mediaRef) {
      var open = document.createElement("button");
      open.textContent = "Open";
      bindAction(open, function () {
        var token = ((item.eventsUrl || item.url || "").split("/preview/")[1] || "").split("/")[0].split("?")[0];
        return fetch(origin + "/preview/" + token + "/open").then(function (r) {
          if (!r.ok) throw new Error("Could not open in Palmier.");
          setStatus("Opened in Palmier.");
        });
      });
      row.appendChild(open);
    }
    var hide = document.createElement("button");
    hide.textContent = "Hide";
    hide.addEventListener("click", function () {
      var card = row.closest(".card");
      if (card) card.remove();
      reportSize();
    });
    row.appendChild(hide);
    return row;
  }
  function fillMedia(card, item) {
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
  }
  function renderAssets(sc) {
    var items = itemsFrom(sc);
    var root = document.getElementById("root");
    root.innerHTML = "";
    var grid = document.createElement("div");
    grid.className = "grid " + (items.length === 1 ? "one" : "many");
    items.forEach(function (item) {
      var card = document.createElement("div");
      card.className = "card " + orientation(item, null);
      fillMedia(card, item);
      card.appendChild(actionBar(item, sc));
      grid.appendChild(card);
      watch(item, function () {
        card.innerHTML = "";
        card.className = "card " + orientation(item, null);
        fillMedia(card, item);
        card.appendChild(actionBar(item, sc));
        reportSize();
      });
    });
    root.appendChild(grid);
    var status = document.createElement("div");
    status.id = "status";
    status.className = "status";
    root.appendChild(status);
    reportSize();
  }
  function renderCut(sc) {
    var root = document.getElementById("root");
    root.innerHTML = "";
    var frames = sc.frames || [];
    if (!frames.length) {
      document.getElementById("m").style.display = "block";
      document.getElementById("m").textContent = sc.message || "No preview.";
      reportSize();
      return;
    }
    var index = 0;
    var playing = false;
    var stage = document.createElement("div");
    stage.className = "stage";
    var img = document.createElement("img");
    img.src = frames[0].url;
    img.addEventListener("load", reportSize);
    stage.appendChild(img);
    var strip = document.createElement("div");
    strip.className = "strip";
    var thumbs = [];
    frames.forEach(function (frame, i) {
      var thumb = document.createElement("img");
      thumb.src = frame.url;
      thumb.addEventListener("click", function () { show(i); });
      strip.appendChild(thumb);
      thumbs.push(thumb);
    });
    function show(i) {
      index = i;
      img.src = frames[i].url;
      thumbs.forEach(function (t, n) { t.className = n === i ? "on" : ""; });
    }
    show(0);
    var bar = document.createElement("div");
    bar.className = "bar";
    var play = document.createElement("button");
    play.textContent = "Play";
    play.addEventListener("click", function () {
      playing = !playing;
      play.textContent = playing ? "Pause" : "Play";
      clearInterval(playTimer);
      if (!playing) return;
      var fps = sc.fps || 30;
      var stepMs = Math.max(80, Math.round(1000 / Math.max(1, frames.length / 2)));
      if (frames.length > 1 && sc.endFrame > sc.startFrame) {
        stepMs = Math.max(80, Math.round(((sc.endFrame - sc.startFrame) / fps) * 1000 / frames.length));
      }
      playTimer = setInterval(function () {
        show((index + 1) % frames.length);
      }, stepMs);
    });
    bar.appendChild(play);
    if (sc.intent === "look" && sc.applyLook && sc.applyLook.length) {
      var apply = document.createElement("button");
      apply.textContent = sc.look && sc.look.mode === "sample" ? "Add captions" : "Apply look";
      bindAction(apply, function () {
        var chain = Promise.resolve();
        sc.applyLook.forEach(function (call) {
          chain = chain.then(function () { return callTool(call.name, call.arguments || {}); });
        });
        return chain.then(function () { setStatus("Applied to the timeline."); });
      });
      bar.appendChild(apply);
    }
    root.appendChild(stage);
    root.appendChild(strip);
    root.appendChild(bar);
    if (sc.intent === "look") {
      var note = document.createElement("div");
      note.className = "note";
      note.textContent = "Preview only. The timeline is unchanged until you apply.";
      root.appendChild(note);
    }
    var status = document.createElement("div");
    status.id = "status";
    status.className = "status";
    root.appendChild(status);
    reportSize();
  }
  function render(sc) {
    if (!sc) return;
    closeStreams();
    var msg = document.getElementById("m");
    msg.style.display = "none";
    if (sc.intent === "cut" || sc.intent === "look" || (sc.frames && sc.frames.length)) {
      renderCut(sc);
      return;
    }
    var items = itemsFrom(sc);
    if (!items.length) {
      msg.style.display = "block";
      msg.textContent = sc.message || "No preview.";
      document.getElementById("root").innerHTML = "";
      reportSize();
      return;
    }
    renderAssets(sc);
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
    appInfo: { name: "palmier-preview", version: "0.2.0" },
    appCapabilities: { tools: {} }
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
