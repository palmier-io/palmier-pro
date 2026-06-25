> Esta traducción fue generada por IA. Si encuentras un error, abre un PR.

<p align="right">
  <a href="../remove-silence.md">English</a> ·
  <strong>Español</strong> ·
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
  <a href="fr.md">Français</a> ·
  <a href="ru.md">Русский</a>
</p>

# Eliminar silencio

Detecta y elimina automáticamente las regiones silenciosas de un clip. La detección se ejecuta completamente en el dispositivo a partir de la forma de onda de audio del clip — no se requiere conexión a internet ni transcripción.

---

## Escritorio

### 1. Selecciona un clip

Haz clic en cualquier **clip de video o audio** en la línea de tiempo. El botón Eliminar silencio solo se activa cuando hay un único clip seleccionado (o un par de audio/video vinculado).

### 2. Abre el panel

Haz clic en el **ícono de forma de onda con menos** (`waveform.badge.minus`) en la barra de herramientas, o elige **Editar → Eliminar silencio**.

El panel se abre e inmediatamente comienza a detectar silencios con la configuración actual.

### 3. Ajusta los parámetros

| Parámetro | Predeterminado | Descripción |
|-----------|----------------|-------------|
| **Threshold** | −35 dB | El nivel mínimo de volumen por debajo del cual el audio se considera silencioso. Sube hacia 0 dB (p. ej. −25 dB) para capturar pausas más suaves; baja (p. ej. −45 dB) para eliminar solo el silencio casi total. |
| **Min duration** | 0.5 s | El silencio más corto que se eliminará. Auméntalo para conservar respiraciones naturales y pausas breves; redúcelo para cortar incluso los silencios muy cortos. |
| **Edge padding** | 0.05 s | La cantidad de audio que se conserva en cada lado de un silencio detectado, para que el habla y las notas no se corten. Auméntalo si se están cortando palabras. |

Tras modificar cualquier parámetro, haz clic en **Detect** para volver a ejecutar la detección con los nuevos valores. El panel muestra cuántos silencios se encontraron.

### 4. Aplicar

Haz clic en **Remove Silences**. Las regiones silenciosas se eliminan en cascada — los clips se cierran y todo lo que sigue se desplaza hacia la izquierda para llenar los huecos. La edición es una única acción que se puede deshacer: presiona **⌘Z** para restaurar el original.

---

## Clips de audio/video vinculados

Cuando un clip de video y su audio están vinculados (el ícono de cadena está cerrado en ambas pistas), al seleccionar cualquiera de los dos se selecciona el par. Eliminar silencio lee la forma de onda de audio para la detección y corta **ambas pistas** exactamente en los mismos fotogramas, manteniendo el audio y el video sincronizados.

---

## Agente de IA (MCP)

Cuando Palmier Pro está en ejecución, expone un servidor MCP en `http://127.0.0.1:19789/mcp`. Cualquier agente conectado (Claude, Codex, Cursor, etc.) puede eliminar silencios usando la herramienta `remove_silence`.

### Lenguaje natural

```
Remove the silences from the first clip
Cut all the dead air
Tighten the pauses — use a threshold of -30 dB
Remove silence, minimum gap 1 second
```

### Herramienta: `remove_silence`

```json
{
  "name": "remove_silence",
  "arguments": {
    "clipId": "<id from get_timeline>",
    "thresholdDb": -35,
    "minSilenceDuration": 0.5,
    "edgePadding": 0.05
  }
}
```

#### Parámetros

| Parámetro | Tipo | Predeterminado | Descripción |
|-----------|------|----------------|-------------|
| `clipId` | string | **requerido** | ID del clip obtenido de `get_timeline`. Debe ser un clip de audio o un clip de video con audio. |
| `thresholdDb` | number | `−35` | Nivel mínimo de volumen en dBFS (debe ser ≤ 0). El audio más silencioso que este valor se trata como silencio. |
| `minSilenceDuration` | number | `0.5` | Duración mínima del silencio en segundos para ser eliminado. |
| `edgePadding` | number | `0.05` | Segundos de audio que se conservan en cada lado de un silencio detectado. |

#### Respuesta

```json
{
  "removedSilences": 12,
  "removedFrames": 1440,
  "thresholdDb": -35,
  "note": "Removed silent regions and closed the gaps. Re-read get_timeline or get_transcript before another edit."
}
```

#### Ejemplo de flujo de trabajo

```
1. get_timeline          → encontrar el ID del clip
2. remove_silence        → detectar y eliminar silencios
3. get_transcript        → verificar el resultado (opcional)
4. undo                  → revertir si el resultado no es correcto
```

---

## Consejos

- **¿No se elimina nada?** Reduce el threshold (p. ej. −30 dB) o disminuye **Min duration**.
- **¿Se corta el habla?** Aumenta **Edge padding** (p. ej. 0.1 s) para conservar más audio alrededor de cada corte.
- **¿Demasiados cortes?** Aumenta **Min duration** (p. ej. 1.0 s) para omitir las pausas cortas.
- **¿Los clips vinculados quedan desincronizados tras desvincularlos?** Ejecuta siempre Eliminar silencio mientras los clips están vinculados para que ambas pistas reciban cortes idénticos.
