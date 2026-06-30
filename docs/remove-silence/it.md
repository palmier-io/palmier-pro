> Questa traduzione è stata generata dall'IA. Se trovi un errore, apri una PR.

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
  <strong>Italiano</strong> ·
  <a href="pt-BR.md">Português (Brasil)</a> ·
  <a href="fr.md">Français</a> ·
  <a href="ru.md">Русский</a>
</p>

# Rimuovi silenzio

Rileva e rimuove automaticamente le regioni silenziose da una clip. Il rilevamento avviene interamente sul dispositivo a partire dalla forma d'onda audio della clip — non è richiesta connessione a internet né trascrizione.

## Desktop

### 1. Seleziona una clip
Fai clic su qualsiasi **clip video o audio** nella timeline. Il pulsante Rimuovi silenzio si attiva solo quando è selezionata una singola clip (o una coppia audio/video collegata).

### 2. Apri il pannello
Fai clic sull'**icona forma d'onda con meno** (`waveform.badge.minus`) nella barra degli strumenti, oppure scegli **Modifica → Rimuovi silenzio**. Il pannello si apre e avvia immediatamente il rilevamento dei silenzi con le impostazioni correnti.

### 3. Regola i parametri

| Parametro | Predefinito | Descrizione |
|-----------|-------------|-------------|
| **Threshold** | −35 dB | Il livello minimo di volume al di sotto del quale l'audio è considerato silenzioso. Avvicina a 0 dB per rilevare pause più lievi; abbassa per rimuovere solo i silenzi quasi totali. |
| **Min duration** | 0,5 s | La durata minima del silenzio che verrà rimosso. |
| **Edge padding** | 0,05 s | Audio mantenuto su ciascun lato di un silenzio rilevato per evitare che il parlato venga tagliato. |

Dopo aver modificato un parametro, fai clic su **Detect** per rieseguire il rilevamento. Fai clic su **Remove Silences** per applicare. Premi **⌘Z** per annullare.

## Clip audio/video collegate
Quando collegate, selezionare una delle due clip seleziona la coppia. I tagli vengono applicati a **entrambe le tracce** sugli stessi fotogrammi.

## Agente AI (MCP)
Server MCP su `http://127.0.0.1:19789/mcp`. Usa lo strumento `remove_silence`.

### Strumento: `remove_silence`
```json
{"name":"remove_silence","arguments":{"clipId":"<id>","thresholdDb":-35,"minSilenceDuration":0.5,"edgePadding":0.05}}
```

#### Parametri
| Parametro | Tipo | Predefinito | Descrizione |
|-----------|------|-------------|-------------|
| `clipId` | string | **obbligatorio** | ID della clip da `get_timeline`. |
| `thresholdDb` | number | `−35` | Livello minimo in dBFS (≤ 0). |
| `minSilenceDuration` | number | `0.5` | Silenzio minimo in secondi. |
| `edgePadding` | number | `0.05` | Secondi mantenuti su ciascun lato. |

## Suggerimenti
- **Niente viene rimosso?** Abbassa il threshold o riduci Min duration.
- **Il parlato viene tagliato?** Aumenta Edge padding.
- **Troppi tagli?** Alza Min duration.
- **Clip collegate non sincronizzate?** Esegui Rimuovi silenzio mentre le clip sono collegate.
