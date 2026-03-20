#!/bin/bash
# =============================================================================
# Uso: ./process-audio.sh <audio.flac> [--lang CODIGO] [--pad-start MS] [--pad-end MS]
#
# Exemplos:
#   ./process-audio.sh podcast.flac
#   ./process-audio.sh podcast.flac --lang pt
#   ./process-audio.sh podcast.flac --lang es --pad-start 200 --pad-end 200
# =============================================================================

# ---------- argumento posicional: arquivo de áudio ---------------------------
if [[ $# -lt 1 || "$1" == -* ]]; then
  echo "Uso: $0 <audio.flac> [--lang CODIGO] [--pad-start MS] [--pad-end MS]"
  echo "  --lang       Código de idioma para o WhisperX (padrão: en)"
  echo "               Exemplos: en, pt, es, fr, de, ja, zh"
  echo "  --pad-start  Padding antes de cada segmento em ms (padrão: 150)"
  echo "  --pad-end    Padding após cada segmento em ms     (padrão: 150)"
  exit 0
fi

SOURCE_ORIGINAL_AUDIO_FLAC="$1"
shift

[[ -f "$SOURCE_ORIGINAL_AUDIO_FLAC" ]] \
  || { echo "Erro: arquivo não encontrado: $SOURCE_ORIGINAL_AUDIO_FLAC"; exit 1; }

# ---------- defaults ---------------------------------------------------------
WHISPERX_LANG="en"
PAD_START=150
PAD_END=150

# ---------- parse args restantes ---------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang)      WHISPERX_LANG="$2"; shift 2 ;;
    --pad-start) PAD_START="$2";     shift 2 ;;
    --pad-end)   PAD_END="$2";       shift 2 ;;
    -h|--help)
      echo "Uso: $0 <audio.flac> [--lang CODIGO] [--pad-start MS] [--pad-end MS]"
      exit 0 ;;
    *) echo "Opção desconhecida: $1"; exit 1 ;;
  esac
done

# ---------- deriva nomes a partir do arquivo de entrada ----------------------
FILENAME_ORIGINAL_AUDIO="$(basename "${SOURCE_ORIGINAL_AUDIO_FLAC%.*}")"

DEST_SRT_AUDIO="${FILENAME_ORIGINAL_AUDIO}.srt"
DEST_TXT_AUDIO="${FILENAME_ORIGINAL_AUDIO}.txt"

# Pasta raiz que agrupa todo o material gerado para este áudio.
# Estrutura final:
#   clips-<nome>/
#     ├── <nome>.srt
#     ├── <nome>.txt
#     ├── clips/
#     │   ├── 001_Hello_how_are_you.flac
#     │   ├── 001_Hello_how_are_you.txt
#     │   └── ...
#     └── prosody/
#           ├── orig_*.mp4
#           ├── orig_blind_*.mp4
#           ├── lp_blind1_*.mp4
#           ├── lp_blind3_*.mp4
#           ├── lp_*.flac
#           ├── pratica_*.m3u
#           └── pratica_COMPLETA.m3u
ROOT_DIR="clips-${FILENAME_ORIGINAL_AUDIO}"
INPUT_DIR="${ROOT_DIR}/clips"
PROSODY_DIR="${ROOT_DIR}/prosody"

source whisper-env/bin/activate

pip install librosa numpy pillow --break-system-packages

echo "Idioma selecionado: $WHISPERX_LANG"
whisperx "$SOURCE_ORIGINAL_AUDIO_FLAC" --model large-v2 --language "$WHISPERX_LANG" --output_format srt

# Extrai o texto reconhecido do SRT e salva como .txt
echo "Exportando texto reconhecido para $DEST_TXT_AUDIO..."
grep -v '^[0-9]*$' "$DEST_SRT_AUDIO" \
  | grep -v '^[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\},[0-9]\{3\} --> ' \
  | sed '/^[[:space:]]*$/d' \
  > "$DEST_TXT_AUDIO"
echo "  ✓ Texto salvo em: $DEST_TXT_AUDIO"

# Move o .srt e .txt para dentro da pasta raiz
mkdir -p "$ROOT_DIR"
mv "$DEST_SRT_AUDIO" "$ROOT_DIR/"
mv "$DEST_TXT_AUDIO" "$ROOT_DIR/"

python split_audio.py "$SOURCE_ORIGINAL_AUDIO_FLAC" \
  "$ROOT_DIR/$DEST_SRT_AUDIO" \
  "$INPUT_DIR" \
  --pad-start "$PAD_START" --pad-end "$PAD_END"

./prosody_lowpass.sh --input "$INPUT_DIR" --output "$PROSODY_DIR"

echo ""
echo "=============================================="
echo " Todo o material está em: $ROOT_DIR/"
echo " Para zipar:"
echo "   zip -r ${FILENAME_ORIGINAL_AUDIO}.zip $ROOT_DIR/"
echo "=============================================="