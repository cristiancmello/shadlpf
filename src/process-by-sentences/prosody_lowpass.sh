#!/usr/bin/env bash
# =============================================================================
# prosody_lowpass.sh
# Extração de prosódia para uso didático em L2 (inglês americano)
#
# Baseado em:
#   Luu et al. (2020) "Prosody-based techniques for enhancing EFL learners'
#   listening skills", OpenTESOL International Conference.
#
#   Parsons et al. (2025) "Effects of prosodic information on dialect
#   classification using Whisper features", Interspeech 2025.
#
# Corte fixo em 400 Hz (Butterworth de ordem variável):
#   - Elimina inteligibilidade lexical (~0% compreensão de palavras)
#   - Preserva entonação, ritmo e contornos de F0
#   - Preserva F0 + harmônicos melódicos (até ~400 Hz)
#   - Elimina conteúdo segmental: −36 dB a 800 Hz, −72 dB a 1600 Hz
#   - Alinhado com o limite superior da literatura de percepção humana (400 Hz)
#
# Protocolo de prática gerado (Luu et al. 2020):
#   Fase 1 — 15× filtrado  : ouvir só a melodia + movimento corporal
#   Fase 2 — 10× original  : ouvir o áudio normal, notar entonação
#   Fase 3 — 10× filtrado  : repetir/hum + movimento corporal
#
# Uso:
#   ./prosody_lowpass.sh [--input DIR] [--output DIR] [--sr N] [--mono]
#
# Flags opcionais:
#   --input  DIR  Pasta de entrada (padrão: ./clips)
#   --output DIR  Pasta de saída   (padrão: ./clips/prosody)
#   --sr N        Sample rate de saída em Hz (padrão: 16000)
#   --rolloff N   Rolloff em dB/oitava: 12, 24 ou 36 (padrão: 36)
#   --mono        Gera versão monotonizada (condição controle — requer Praat)
# =============================================================================

set -euo pipefail

# ---------- defaults ---------------------------------------------------------
INPUT_DIR="./clips"
OUTPUT_DIR="./clips/prosody"
SAMPLE_RATE=16000
DO_MONO=0

LP_CUTOFF=400
LP_ROLLOFF=36

# ---------- parse args -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mono)    DO_MONO=1; shift ;;
    --rolloff) LP_ROLLOFF="$2"; shift 2 ;;
    --sr)      SAMPLE_RATE="$2"; shift 2 ;;
    --input)   INPUT_DIR="$2"; shift 2 ;;
    --output)  OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Opção desconhecida: $1"; exit 1 ;;
  esac
done

# ---------- verificações -----------------------------------------------------
command -v ffmpeg  >/dev/null 2>&1 || { echo "ERRO: ffmpeg não encontrado."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERRO: python3 não encontrado."; exit 1; }

python3 - <<'PYCHECK'
try:
    import librosa, numpy
except ImportError as e:
    print(f"ERRO: dependência Python ausente: {e}")
    print("Instale com: pip install librosa numpy --break-system-packages")
    exit(1)
PYCHECK

if [[ ! -d "$INPUT_DIR" ]]; then
  echo "ERRO: pasta de entrada '$INPUT_DIR' não encontrada."
  exit 1
fi

shopt -s nullglob
FILES=("$INPUT_DIR"/*.flac "$INPUT_DIR"/*.wav "$INPUT_DIR"/*.mp3)
shopt -u nullglob

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "ERRO: nenhum arquivo .flac/.wav/.mp3 encontrado em '$INPUT_DIR'."
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
[[ $DO_MONO -eq 1 ]] && mkdir -p "$OUTPUT_DIR/mono"

# ---------- detecção de ambiente WSL -----------------------------------------
IS_WSL=0
WSL_DISTRO=""
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL=1
  WSL_DISTRO=$(wslpath -w / 2>/dev/null | cut -d'\\' -f3 || echo "Ubuntu")
  echo " Ambiente  : WSL detectado (distro: ${WSL_DISTRO})"
  echo "             Playlists geradas com caminhos Windows (\\\\wsl.localhost\\...)"
fi

to_playlist_path() {
  local linux_path="$1"
  if [[ $IS_WSL -eq 1 ]]; then
    wslpath -w "$linux_path" 2>/dev/null || echo "$linux_path"
  else
    echo "$linux_path"
  fi
}

# ---------- constrói string de filtro cascateado para ffmpeg ----------------
build_lp_filter() {
  local passes
  case "$LP_ROLLOFF" in
    12) passes=1 ;;
    24) passes=2 ;;
    36) passes=3 ;;
    *)  echo "AVISO: rolloff ${LP_ROLLOFF} dB não suportado. Usando 36 dB." >&2
        passes=3 ;;
  esac
  local stage="lowpass=f=${LP_CUTOFF}:poles=2"
  local filter="$stage"
  for _ in $(seq 2 $passes); do
    filter="${filter},${stage}"
  done
  echo "$filter"
}

# ---------- Python helper: extrai duração e F0 médio (só para log) ----------
get_info() {
  local filepath="$1"
  python3 - "$filepath" <<'PYEOF'
import sys, warnings
warnings.filterwarnings("ignore")
import numpy as np
import librosa

path = sys.argv[1]
y, sr = librosa.load(path, sr=None, mono=True)
duration = librosa.get_duration(y=y, sr=sr)

f0, voiced_flag, _ = librosa.pyin(
    y, sr=sr,
    fmin=librosa.note_to_hz('C2'),
    fmax=librosa.note_to_hz('C6'),
    frame_length=2048
)
voiced_f0 = f0[voiced_flag & ~np.isnan(f0)]
f0_mean = float(np.mean(voiced_f0)) if len(voiced_f0) > 0 else 0.0

print(f"{duration:.2f} {f0_mean:.1f}")
PYEOF
}

# ---------- sanitiza nome para uso em nomes de arquivo e playlists ----------
sanitize_name() {
  python3 - "$1" <<'PYSANITIZE'
import sys, re
name = sys.argv[1]
name = re.sub(r"[,'!?.()\[\]]", "", name)
name = re.sub(r"[_\s]+", "_", name)
name = name.strip("_")
print(name)
PYSANITIZE
}

# ---------- lê texto completo do .txt sidecar gerado pelo split_audio.py ----
# O split_audio.py salva um .txt com o mesmo nome base do .flac contendo
# a transcrição completa (sem truncamento de 60 chars do nome do arquivo).
# Fallback: reconstrói a partir do nome caso o .txt não exista.
read_label() {
  local filepath="$1"          # caminho completo do .flac
  local txt="${filepath%.*}.txt"
  if [[ -f "$txt" ]]; then
    cat "$txt"
  else
    # fallback: remove prefixo numérico e troca underscores por espaços
    python3 - "$(basename "${filepath%.*}")" <<'PYLABEL'
import sys, re
name = sys.argv[1]
name = re.sub(r"^\d+_", "", name)
name = name.replace("_", " ").strip()
print(name)
PYLABEL
  fi
}

# ---------- gera vídeo MP4 com tela preta e legenda hardcoded ---------------
# O drawtext do ffmpeg não consegue medir largura real de texto em pixels,
# causando corte em frases longas. A solução é usar o Pillow (Python) para
# renderizar o frame de texto como PNG — que mede e quebra linhas com precisão
# — e passá-lo ao ffmpeg como overlay sobre fundo preto.
#
# $1 = arquivo de áudio de entrada
# $2 = caminho de saída .mp4
# $3 = texto da legenda (frase)
# $4 = rótulo de fase exibido no topo
make_video() {
  local audio_in="$1"
  local mp4_out="$2"
  local label_text="$3"
  local phase_text="$4"
  local show_label="${5:-1}"   # "1" exibe o texto da frase; "0" tela preta

  local tmp_dir
  tmp_dir=$(mktemp -d /tmp/prosody_vf_XXXXXX)
  local frame_png="$tmp_dir/frame.png"

  # ── Renderiza o frame PNG via Pillow ────────────────────────────────────
  # Pillow mede a largura real de cada palavra em pixels antes de quebrar,
  # garantindo que nenhuma linha ultrapasse a largura do vídeo.
  python3 - "$label_text" "$phase_text" "$show_label" "$frame_png" <<'PYRENDER'
import sys
from PIL import Image, ImageDraw, ImageFont

label_text = sys.argv[1]
phase_text = sys.argv[2]
show_label = sys.argv[3] == "1"
out_path   = sys.argv[4]

VID_W, VID_H   = 1920, 1080
FONT_SIZE_PHASE = 48
FONT_SIZE_LABEL = 72
LINE_SPACING    = 20   # px extra entre linhas da frase
MARGIN          = 80   # margem lateral mínima em px
COLOR_PHASE     = (170, 170, 170)
COLOR_LABEL     = (255, 255, 255)
COLOR_BG        = (0, 0, 0)

img  = Image.new("RGB", (VID_W, VID_H), COLOR_BG)
draw = ImageDraw.Draw(img)

# Tenta carregar fonte do sistema; cai para a fonte padrão do Pillow se falhar
def load_font(size):
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf",
        "/usr/share/fonts/truetype/ubuntu/Ubuntu-B.ttf",
    ]
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            pass
    return ImageFont.load_default()

font_phase = load_font(FONT_SIZE_PHASE)
font_label = load_font(FONT_SIZE_LABEL)

# ── Rótulo de fase (topo, centralizado) ─────────────────────────────────
bbox_phase = draw.textbbox((0, 0), phase_text, font=font_phase)
pw = bbox_phase[2] - bbox_phase[0]
draw.text(((VID_W - pw) // 2, 40), phase_text, font=font_phase, fill=COLOR_PHASE)

# ── Quebra de linha por largura real em pixels ───────────────────────────
max_w = VID_W - MARGIN * 2

def wrap_by_pixels(text, font, max_px):
    words = text.split()
    lines, current = [], []
    for word in words:
        test = " ".join(current + [word])
        bb   = draw.textbbox((0, 0), test, font=font)
        if bb[2] - bb[0] <= max_px:
            current.append(word)
        else:
            if current:
                lines.append(" ".join(current))
            current = [word]
    if current:
        lines.append(" ".join(current))
    return lines or [text]

# Só desenha o texto da frase se show_label=True
if show_label:
    lines = wrap_by_pixels(label_text, font_label, max_w)

    # Altura de uma linha
    sample_bb = draw.textbbox((0, 0), "Ag", font=font_label)
    line_h = sample_bb[3] - sample_bb[1] + LINE_SPACING

    # Bloco centralizado verticalmente (abaixo do rótulo de fase)
    area_top  = 120
    block_h   = line_h * len(lines)
    y_start   = area_top + ((VID_H - area_top) - block_h) // 2

    for i, line in enumerate(lines):
        bb  = draw.textbbox((0, 0), line, font=font_label)
        lw  = bb[2] - bb[0]
        x   = (VID_W - lw) // 2
        y   = y_start + i * line_h
        draw.text((x, y), line, font=font_label, fill=COLOR_LABEL)

img.save(out_path, "PNG")
PYRENDER

  if [[ $? -ne 0 || ! -f "$frame_png" ]]; then
    echo "ERRO: Pillow falhou ao renderizar frame para '$mp4_out'" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  # ── Monta o vídeo: loop do PNG + áudio ──────────────────────────────────
  ffmpeg -y \
    -loop 1 -framerate 1 -i "$frame_png" \
    -i "$audio_in" \
    -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p \
    -c:a aac -b:a 128k \
    -shortest \
    "$mp4_out" \
    2>/dev/null
  local status=$?

  rm -rf "$tmp_dir"
  return $status
}

# ---------- gera playlist M3U do protocolo (4 fases) ------------------------
# Fase 1 — 15× filtrado  : tela preta, sem texto (treino auditivo puro)
# Fase 2 — 10× original  : tela preta, sem texto
# Fase 3 — 10× filtrado  : tela preta, sem texto
# Fase 4 — 10× original  : texto revelado (confirmação)
generate_playlist() {
  local label="$1"         # texto da frase (legível)
  local clean_name="$2"    # nome sanitizado
  local orig_mp4="$3"       # vídeo original COM texto (fase 4)
  local lp_mp4="$4"         # reservado (filtrado + texto)
  local orig_blind="$5"     # vídeo original SEM texto (fase 2)
  local lp_blind1="$6"      # vídeo filtrado SEM texto (fase 1)
  local lp_blind3="$7"      # vídeo filtrado SEM texto (fase 3)
  local playlist="$OUTPUT_DIR/pratica_${clean_name}.m3u"

  local orig_entry orig_blind_entry lp_blind1_entry lp_blind3_entry
  orig_entry=$(to_playlist_path "$orig_mp4")
  orig_blind_entry=$(to_playlist_path "$orig_blind")
  lp_blind1_entry=$(to_playlist_path "$lp_blind1")
  lp_blind3_entry=$(to_playlist_path "$lp_blind3")

  {
    echo "#EXTM3U"
    echo ""
    echo "# ============================================================"
    echo "# Protocolo de prática prosódica — 4 fases"
    echo "# Frase: ${label}"
    echo "# ============================================================"
    echo ""
    echo "# --- FASE 1: 15x filtrado — SEM texto (ouça a melodia) ---"
    for i in $(seq 1 15); do
      echo "#EXTINF:-1,F1-$(printf '%02d' $i)/15 | Filtrado | sem texto"
      echo "$lp_blind1_entry"
    done
    echo ""
    echo "# --- FASE 2: 10x original — SEM texto (note a entonação) ---"
    for i in $(seq 1 10); do
      echo "#EXTINF:-1,F2-$(printf '%02d' $i)/10 | Original | sem texto"
      echo "$orig_blind_entry"
    done
    echo ""
    echo "# --- FASE 3: 10x filtrado — SEM texto (hum + movimento) ---"
    for i in $(seq 1 10); do
      echo "#EXTINF:-1,F3-$(printf '%02d' $i)/10 | Filtrado | sem texto"
      echo "$lp_blind1_entry"
    done
    echo ""
    echo "# --- FASE 4: 10x original — TEXTO REVELADO ---"
    for i in $(seq 1 10); do
      echo "#EXTINF:-1,F4-$(printf '%02d' $i)/10 | Original | ${label}"
      echo "$orig_entry"
    done
  } > "$playlist"

  echo "$playlist"
}

# ---------- loop principal ---------------------------------------------------
TOTAL=${#FILES[@]}
COUNT=0
FAILED=0
PLAYLISTS=()

echo ""
echo "=============================================="
echo " prosody_lowpass.sh — Uso didático L2"
echo " Baseado em Luu et al. (OpenTESOL 2020)"
echo "=============================================="
echo " Entrada    : $INPUT_DIR"
echo " Saída      : $OUTPUT_DIR"
echo " Arquivos   : $TOTAL"
echo " Corte LP   : ${LP_CUTOFF} Hz  |  Rolloff: ${LP_ROLLOFF} dB/oitava"
echo " Protocolo  : 15× filtrado → 10× original → 10× filtrado → 10× original+texto"
echo " SR saída   : ${SAMPLE_RATE} Hz"
echo " Legenda    : texto da frase queimado no vídeo MP4"
echo " Mono ctrl  : $([ $DO_MONO -eq 1 ] && echo 'sim' || echo 'não')"
echo "----------------------------------------------"
echo ""

for FILEPATH in "${FILES[@]}"; do
  BASENAME=$(basename "$FILEPATH")
  NAME="${BASENAME%.*}"
  COUNT=$((COUNT + 1))

  printf "[%d/%d] %s\n" "$COUNT" "$TOTAL" "$BASENAME"

  # Info para log
  if INFO=$(get_info "$FILEPATH" 2>/dev/null); then
    read -r DURATION F0_MEAN <<< "$INFO"
    printf "  Duração  : %.1f s  |  F0 médio: %.0f Hz\n" "$DURATION" "$F0_MEAN"
  else
    F0_MEAN=150
    DURATION=0
  fi
  printf "  Corte fc : %d Hz (fixo L2)\n" "$LP_CUTOFF"

  # Nome limpo e texto da legenda
  CLEAN_NAME=$(sanitize_name "$NAME")
  LABEL_TEXT=$(read_label "$FILEPATH")
  printf "  Legenda  : %s\n" "$LABEL_TEXT"

  # ---- 1. Gera áudio low-pass (FLAC intermediário) --------------------------
  LP_FLAC="$OUTPUT_DIR/lp_${CLEAN_NAME}.flac"

  ffmpeg -y -i "$FILEPATH" \
    -af "$(build_lp_filter)" \
    -ac 1 \
    -ar "$SAMPLE_RATE" \
    -c:a flac \
    "$LP_FLAC" \
    2>/dev/null \
  && printf "  ✓ low-pass (flac) → %s\n" "$(basename "$LP_FLAC")" \
  || { printf "  ✗ ERRO ao gerar low-pass\n"; FAILED=$((FAILED+1)); continue; }

  # ---- 2. Gera os 4 vídeos MP4 -------------------------------------------------
  # Fases 1-3: tela preta sem texto (show_label=0)
  # Fase 4:    texto revelado (show_label=1)
  ORIG_MP4="$OUTPUT_DIR/orig_${CLEAN_NAME}.mp4"          # fase 4: original + texto
  LP_MP4="$OUTPUT_DIR/lp_${CLEAN_NAME}.mp4"              # reservado (filtrado + texto)
  ORIG_BLIND_MP4="$OUTPUT_DIR/orig_blind_${CLEAN_NAME}.mp4"  # fase 2: original sem texto
  LP_BLIND1_MP4="$OUTPUT_DIR/lp_blind1_${CLEAN_NAME}.mp4"    # fase 1: filtrado sem texto
  LP_BLIND3_MP4="$OUTPUT_DIR/lp_blind3_${CLEAN_NAME}.mp4"    # fase 3: filtrado sem texto

  # Fase 4 — original COM texto revelado
  make_video "$FILEPATH"  "$ORIG_MP4"        "$LABEL_TEXT" "FASE 4 — Texto revelado" "1" \
  && printf "  ✓ vídeo fase 4     → %s\n" "$(basename "$ORIG_MP4")" \
  || { printf "  ✗ ERRO ao gerar vídeo fase 4\n"; FAILED=$((FAILED+1)); continue; }

  # Fase 1 — filtrado SEM texto
  make_video "$LP_FLAC"   "$LP_BLIND1_MP4"   "$LABEL_TEXT" "FASE 1 — Filtrado ${LP_CUTOFF} Hz" "0" \
  && printf "  ✓ vídeo fase 1     → %s\n" "$(basename "$LP_BLIND1_MP4")" \
  || { printf "  ✗ ERRO ao gerar vídeo fase 1\n"; FAILED=$((FAILED+1)); continue; }

  # Fase 3 — filtrado SEM texto
  make_video "$LP_FLAC"   "$LP_BLIND3_MP4"   "$LABEL_TEXT" "FASE 3 — Filtrado ${LP_CUTOFF} Hz" "0" \
  && printf "  ✓ vídeo fase 3     → %s\n" "$(basename "$LP_BLIND3_MP4")" \
  || { printf "  ✗ ERRO ao gerar vídeo fase 3\n"; FAILED=$((FAILED+1)); continue; }

  # Fase 2 — original SEM texto
  make_video "$FILEPATH"  "$ORIG_BLIND_MP4"  "$LABEL_TEXT" "FASE 2 — Original" "0" \
  && printf "  ✓ vídeo fase 2     → %s\n" "$(basename "$ORIG_BLIND_MP4")" \
  || { printf "  ✗ ERRO ao gerar vídeo fase 2\n"; FAILED=$((FAILED+1)); continue; }

  # ---- 3. Playlist do protocolo (4 fases) -----------------------------------
  ABS_ORIG_MP4=$(realpath "$ORIG_MP4")
  ABS_ORIG_BLIND_MP4=$(realpath "$ORIG_BLIND_MP4")
  ABS_LP_BLIND1_MP4=$(realpath "$LP_BLIND1_MP4")
  ABS_LP_BLIND3_MP4=$(realpath "$LP_BLIND3_MP4")
  PLAYLIST=$(generate_playlist "$LABEL_TEXT" "$CLEAN_NAME" "$ABS_ORIG_MP4" "$LP_MP4" "$ABS_ORIG_BLIND_MP4" "$ABS_LP_BLIND1_MP4" "$ABS_LP_BLIND3_MP4")
  PLAYLISTS+=("$PLAYLIST")
  printf "  ✓ playlist         → %s\n" "$(basename "$PLAYLIST")"

  # ---- 4. Monotonização (condição controle, opcional) ----------------------
  if [[ $DO_MONO -eq 1 ]]; then
    MONO_OUT="$OUTPUT_DIR/mono/mono_${NAME}.flac"

    if command -v praat >/dev/null 2>&1; then
      PRAAT_SCRIPT=$(mktemp /tmp/praat_mono_XXXXXX.praat)
      F0_PRAAT=${F0_MEAN:-150}

      cat > "$PRAAT_SCRIPT" <<PRAAT
form Monotonize
  text inputFile
  text outputFile
  real f0mean
endform

sound = Read from file: inputFile\$
manipulation = To Manipulation: 0.01, 75, 600

selectObject: manipulation
pitchTier = Extract pitch tier
Remove points between: 0, Get end time
Add point: 0, f0mean
Add point: Get end time, f0mean

plusObject: manipulation
Replace pitch tier

selectObject: manipulation
sound2 = Get resynthesis (overlap-add)
Save as WAV file: outputFile\$

removeObject: sound, manipulation, pitchTier, sound2
PRAAT

      praat --run "$PRAAT_SCRIPT" \
        "$FILEPATH" "${MONO_OUT%.flac}.wav" "$F0_PRAAT" 2>/dev/null \
      && ffmpeg -y -i "${MONO_OUT%.flac}.wav" \
           -ac 1 -ar "$SAMPLE_RATE" -c:a flac "$MONO_OUT" 2>/dev/null \
      && rm -f "${MONO_OUT%.flac}.wav" \
      && printf "  ✓ mono (Praat) → %s\n" "$(basename "$MONO_OUT")" \
      || printf "  ⚠ Praat falhou. Pulando monotonização.\n"

      rm -f "$PRAAT_SCRIPT"
    else
      printf "  ⚠ Praat não encontrado.\n"
      printf "    Instale com: sudo apt install praat   ou   brew install praat\n"
    fi
  fi

  echo ""
done

# ---------- playlist mestra (todas as frases em sequência) ------------------
MASTER_PLAYLIST="$OUTPUT_DIR/pratica_COMPLETA.m3u"
{
  echo "#EXTM3U"
  echo ""
  echo "# ============================================================"
  echo "# Playlist COMPLETA — todas as frases"
  echo "# Protocolo Luu et al. (OpenTESOL 2020)"
  echo "# 15× filtrado → 10× original → 10× filtrado por frase"
  echo "# ============================================================"
  echo ""
  for pl in "${PLAYLISTS[@]}"; do
    grep -v '^#EXTM3U' "$pl"
  done
} > "$MASTER_PLAYLIST"

# ---------- sumário ----------------------------------------------------------
echo "=============================================="
printf " Concluído : %d/%d arquivos processados\n" "$((COUNT - FAILED))" "$TOTAL"
[[ $FAILED -gt 0 ]] && printf " Erros     : %d\n" "$FAILED"
echo ""
echo " Arquivos gerados:"
echo "   Filtrados (flac) : $OUTPUT_DIR/lp_*.flac"
echo "   Vídeos originais : $OUTPUT_DIR/orig_*.mp4"
echo "   Vídeos filtrados : $OUTPUT_DIR/lp_*.mp4"
echo "   Por frase        : $OUTPUT_DIR/pratica_<nome>.m3u"
echo "   Completa         : $MASTER_PLAYLIST"
[[ $DO_MONO -eq 1 ]] && echo "   Mono ctrl        : $OUTPUT_DIR/mono/mono_*.flac"
echo ""
echo " Como usar:"
echo "   vlc $MASTER_PLAYLIST"
echo "   mpv $MASTER_PLAYLIST"
echo "=============================================="
