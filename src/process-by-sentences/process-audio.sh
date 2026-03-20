#!/bin/bash

# Uso: ./process-audio.sh [--lang CODIGO]
# Exemplos:
#   ./process-audio.sh              (padrão: en)
#   ./process-audio.sh --lang pt
#   ./process-audio.sh --lang es

FILENAME_ORIGINAL_AUDIO="p001"
WHISPERX_LANG="en"   # idioma padrão

# ---------- parse args -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang) WHISPERX_LANG="$2"; shift 2 ;;
    -h|--help)
      echo "Uso: $0 [--lang CODIGO]"
      echo "  --lang  Código de idioma para o WhisperX (padrão: en)"
      echo "          Exemplos: en, pt, es, fr, de, ja, zh"
      exit 0 ;;
    *) echo "Opção desconhecida: $1"; exit 1 ;;
  esac
done

SOURCE_ORIGINAL_AUDIO_FLAC="${FILENAME_ORIGINAL_AUDIO}.flac"
DEST_SRT_AUDIO="${FILENAME_ORIGINAL_AUDIO}.srt"
DEST_TXT_AUDIO="${FILENAME_ORIGINAL_AUDIO}.txt"

# Pasta raiz que agrupa todo o material gerado para este áudio.
# Estrutura final:
#   clips-0-48/
#     ├── 0-48.srt
#     ├── 0-48.txt
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
whisperx $SOURCE_ORIGINAL_AUDIO_FLAC --model large-v2 --language "$WHISPERX_LANG" --output_format srt

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

python split_audio.py $SOURCE_ORIGINAL_AUDIO_FLAC \
  "$ROOT_DIR/$DEST_SRT_AUDIO" \
  "$INPUT_DIR" \
  --pad-start 150 --pad-end 150

./prosody_lowpass.sh --input "$INPUT_DIR" --output "$PROSODY_DIR"

echo ""
echo "=============================================="
echo " Todo o material está em: $ROOT_DIR/"
echo " Para zipar:"
echo "   zip -r ${FILENAME_ORIGINAL_AUDIO}.zip $ROOT_DIR/"
echo "=============================================="
