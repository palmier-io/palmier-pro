> Cette traduction a été générée par IA. Si vous repérez une erreur, ouvrez une PR.

<p align="right">
  <a href="../remove-silence.md">English</a> ·
  <a href="es.md">Español</a> ·
  <a href="zh-CN.md">简体中文</a> ·
  <a href="zh-TW.md">繁體中文</a> ·
  <a href="ja.md">日本語</a> ·
  <a href="ko.md">한국어</a> ·
  <a href="vi.md">Tiếng Việt</a> ·
  <a href="hi.md">हिन्दी</a> ·
  <a href="bn.md">বাংলা</a> ·
  <a href="ar.md">العربية</a> ·
  <a href="it.md">Italiano</a> ·
  <a href="pt-BR.md">Português (Brasil)</a> ·
  <strong>Français</strong> ·
  <a href="ru.md">Русский</a>
</p>

# Supprimer les silences

Détectez et supprimez automatiquement les régions silencieuses d'un clip. La détection s'effectue entièrement sur l'appareil à partir de la forme d'onde audio du clip — aucune connexion internet ni transcription n'est requise.

## Bureau

### 1. Sélectionner un clip
Cliquez sur n'importe quel **clip vidéo ou audio** sur la timeline. Le bouton Supprimer les silences s'active uniquement lorsqu'un seul clip (ou une paire audio/vidéo liée) est sélectionné.

### 2. Ouvrir le panneau
Cliquez sur l'**icône de forme d'onde moins** (`waveform.badge.minus`) dans la barre d'outils, ou choisissez **Édition → Supprimer les silences**. Le panneau s'ouvre et commence immédiatement à détecter les silences avec les paramètres actuels.

### 3. Ajuster les paramètres

| Paramètre | Défaut | Description |
|-----------|--------|-------------|
| **Threshold** | −35 dB | Le plancher de volume en dessous duquel l'audio est considéré comme silencieux. Augmentez vers 0 dB pour détecter les pauses plus discrètes ; diminuez pour ne supprimer que les silences quasi totaux. |
| **Min duration** | 0,5 s | La durée minimale d'un silence pour qu'il soit supprimé. |
| **Edge padding** | 0,05 s | Audio conservé de chaque côté d'un silence détecté pour éviter de couper la parole. |

Après avoir modifié un paramètre, cliquez sur **Detect** pour relancer la détection. Cliquez sur **Remove Silences** pour appliquer. Appuyez sur **⌘Z** pour annuler.

## Clips audio/vidéo liés
Lorsqu'ils sont liés, sélectionner l'un ou l'autre des clips sélectionne la paire. Les coupes s'appliquent **aux deux pistes** aux mêmes images.

## Agent IA (MCP)
Serveur MCP à l'adresse `http://127.0.0.1:19789/mcp`. Utilisez l'outil `remove_silence`.

### Outil : `remove_silence`
```json
{"name":"remove_silence","arguments":{"clipId":"<id>","thresholdDb":-35,"minSilenceDuration":0.5,"edgePadding":0.05}}
```

#### Paramètres
| Paramètre | Type | Défaut | Description |
|-----------|------|--------|-------------|
| `clipId` | string | **requis** | ID du clip obtenu via `get_timeline`. |
| `thresholdDb` | number | `−35` | Plancher de volume en dBFS (≤ 0). |
| `minSilenceDuration` | number | `0.5` | Silence minimum en secondes. |
| `edgePadding` | number | `0.05` | Secondes conservées de chaque côté. |

## Conseils
- **Rien n'est supprimé ?** Abaissez le threshold ou réduisez Min duration.
- **La parole est coupée ?** Augmentez Edge padding.
- **Trop de coupes ?** Augmentez Min duration.
- **Clips liés désynchronisés ?** Lancez Supprimer les silences lorsque les clips sont liés.
