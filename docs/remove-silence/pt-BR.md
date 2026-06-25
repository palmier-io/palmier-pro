> Esta tradução foi gerada por IA. Se encontrar um erro, abra um PR.

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
  <strong>Português (Brasil)</strong> ·
  <a href="fr.md">Français</a> ·
  <a href="ru.md">Русский</a>
</p>

# Remover Silêncio

Detecta e remove automaticamente regiões silenciosas de um clipe. A detecção é feita inteiramente no dispositivo a partir da forma de onda de áudio do clipe — sem necessidade de conexão com a internet ou transcrição.

## Desktop

### 1. Selecione um clipe
Clique em qualquer **clipe de vídeo ou áudio** na linha do tempo. O botão Remover Silêncio só fica ativo quando um único clipe (ou um par de áudio/vídeo vinculado) está selecionado.

### 2. Abra o painel
Clique no **ícone de forma de onda com menos** (`waveform.badge.minus`) na barra de ferramentas, ou escolha **Editar → Remover Silêncio**. O painel abre e começa imediatamente a detectar silêncios com as configurações atuais.

### 3. Ajuste os parâmetros

| Parâmetro | Padrão | Descrição |
|-----------|--------|-----------|
| **Threshold** | −35 dB | O piso de volume abaixo do qual o áudio é considerado silencioso. Aumente em direção a 0 dB para capturar pausas mais suaves; reduza para remover apenas silêncio quase total. |
| **Min duration** | 0,5 s | O menor silêncio que será removido. |
| **Edge padding** | 0,05 s | Áudio mantido em cada lado de um silêncio detectado para que a fala não seja cortada. |

Após alterar qualquer parâmetro, clique em **Detect** para executar a detecção novamente. Clique em **Remove Silences** para aplicar. Pressione **⌘Z** para desfazer.

## Clipes de áudio/vídeo vinculados
Quando vinculados, selecionar qualquer um dos clipes seleciona o par. Os cortes ocorrem em **ambas as faixas** nos mesmos quadros.

## Agente de IA (MCP)
Servidor MCP em `http://127.0.0.1:19789/mcp`. Use a ferramenta `remove_silence`.

### Ferramenta: `remove_silence`
```json
{"name":"remove_silence","arguments":{"clipId":"<id>","thresholdDb":-35,"minSilenceDuration":0.5,"edgePadding":0.05}}
```

#### Parâmetros
| Parâmetro | Tipo | Padrão | Descrição |
|-----------|------|--------|-----------|
| `clipId` | string | **obrigatório** | ID do clipe obtido de `get_timeline`. |
| `thresholdDb` | number | `−35` | Piso de volume em dBFS (≤ 0). |
| `minSilenceDuration` | number | `0.5` | Silêncio mínimo em segundos. |
| `edgePadding` | number | `0.05` | Segundos mantidos em cada lado. |

## Dicas
- **Nada foi removido?** Reduza o threshold ou diminua o Min duration.
- **Fala cortada?** Aumente o Edge padding.
- **Cortes em excesso?** Aumente o Min duration.
- **Clipes vinculados fora de sincronia?** Execute Remover Silêncio com os clipes vinculados.
