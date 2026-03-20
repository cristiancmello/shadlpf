#!/usr/bin/env bash
# =============================================================================
# pre_shadowing.sh — Pré-Shadowing com Low Pass Filter + Transcrição WhisperX
# Dependências: ffmpeg, whisperx (pip install whisperx)
# =============================================================================
# Uso: ./pre_shadowing.sh <arquivo.flac> [frequencia_hz] [compressor_db] [modelo_whisper]
#
# Instalar ffmpeg:
#   Debian/Ubuntu → sudo apt install ffmpeg
#   macOS         → brew install ffmpeg
#
# Instalar whisperx:
#   pip install whisperx
#   (requer Python 3.10+ e PyTorch)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Cores
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()     { echo -e "${CYAN}[•]${RESET} $1"; }
success() { echo -e "${GREEN}[✓]${RESET} $1"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $1"; }
error()   { echo -e "${RED}[✗]${RESET} $1"; exit 1; }
section() { echo -e "\n${BOLD}── $1 ──${RESET}"; }

source whisper-env/bin/activate

# -----------------------------------------------------------------------------
# Verificar dependências
# -----------------------------------------------------------------------------
check_deps() {
  section "Verificando dependências"

  if command -v ffmpeg &>/dev/null; then
    success "ffmpeg encontrado: $(ffmpeg -version 2>&1 | head -1 | cut -d' ' -f1-3)"
  else
    error "ffmpeg não encontrado. Instale com: sudo apt install ffmpeg"
  fi

  if command -v whisperx &>/dev/null; then
    success "whisperx encontrado: $(command -v whisperx)"
    WHISPERX_AVAILABLE=true
  else
    warn "whisperx não encontrado — etapa de transcrição será ignorada."
    warn "Para instalar: pip install whisperx"
    WHISPERX_AVAILABLE=false
  fi
}

# -----------------------------------------------------------------------------
# Argumentos
# -----------------------------------------------------------------------------
INPUT="${1:-}"
LPF_HZ="${2:-300}"
LPF_DB="${3:-36}"            # rolloff do LPF em dB/oitava: 12, 24, 36, 48... (múltiplos de 12)
COMPRESS_DB="${4:--18}"      # threshold do compressor em dB (padrão: -18dB)
WHISPER_MODEL="${5:-base}"   # base é rápido e bom para inglês claro

# Validar LPF_DB e calcular número de passes (1 pass de poles=2 = 12 dB/oitava)
if ! [[ "$LPF_DB" =~ ^[0-9]+$ ]] || (( LPF_DB < 12 )); then
  error "Valor inválido para lpf_db: '$LPF_DB'. Use múltiplos de 12 (ex: 12, 24, 36, 48)."
fi
LPF_PASSES=$(( LPF_DB / 12 ))
# Construir cadeia de filtros lowpass em cascata
LPF_CHAIN=""
for (( i=0; i<LPF_PASSES; i++ )); do
  LPF_CHAIN="${LPF_CHAIN}lowpass=f=${LPF_HZ}:poles=2, "
done

# Validar que COMPRESS_DB é um número (inteiro ou decimal, positivo ou negativo)
if ! [[ "$COMPRESS_DB" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
  error "Valor inválido para compressor_db: '$COMPRESS_DB'. Use um número como -18 ou -12."
fi

# Garantir que o valor tenha sinal negativo (dB de threshold é sempre <= 0)
if (( $(echo "$COMPRESS_DB > 0" | bc -l) )); then
  warn "threshold de compressor deve ser negativo. Convertendo ${COMPRESS_DB} → -${COMPRESS_DB}"
  COMPRESS_DB="-${COMPRESS_DB}"
fi

if [[ -z "$INPUT" ]]; then
  echo -e "Uso: ${BOLD}$0 <arquivo.flac> [lpf_hz] [lpf_db] [compressor_db] [modelo_whisper]${RESET}"
  echo ""
  echo "  LPF — frequência de corte:"
  echo "    300 Hz  → remove quase todo léxico, só ritmo/melodia (padrão)"
  echo "    500 Hz  → mantém um pouco mais de som vocálico"
  echo "    800 Hz  → mais inteligível, bom para iniciantes"
  echo ""
  echo "  LPF — rolloff em dB/oitava (múltiplos de 12):"
  echo "    12 dB   → suave"
  echo "    24 dB   → moderado"
  echo "    36 dB   → próximo do Audacity (padrão)"
  echo "    48 dB   → muito agressivo, quase só graves"
  echo ""
  echo "  Threshold do compressor (Etapa 3 — áudio de estudo):"
  echo "    -12 dB  → compressão mais agressiva, fala mais uniforme"
  echo "    -18 dB  → equilíbrio natural (padrão)"
  echo "    -24 dB  → compressão leve, mais dinâmica preservada"
  echo ""
  echo "  Modelos WhisperX (velocidade × precisão):"
  echo "    tiny    → mais rápido, menos preciso"
  echo "    base    → bom equilíbrio (padrão)"
  echo "    small   → mais preciso, mais lento"
  echo "    medium  → alta precisão"
  echo "    large-v2 → máxima precisão, mais lento"
  echo ""
  exit 1
fi

[[ ! -f "$INPUT" ]] && error "Arquivo não encontrado: $INPUT"

check_deps

# -----------------------------------------------------------------------------
# Paths de saída
# -----------------------------------------------------------------------------
BASENAME="$(basename "${INPUT%.*}")"
OUTDIR="./generated/shad.${BASENAME}"
mkdir -p "$OUTDIR"

LPF_SLOW="$OUTDIR/01_lpf_${LPF_HZ}hz_lento.flac"
LPF_NORM="$OUTDIR/02_lpf_${LPF_HZ}hz_normal.flac"
STUDY_FLAC="$OUTDIR/03_original_estudo.flac"
ORIGINAL_FLAC="$OUTDIR/04_original_puro.flac"
TRANSCRIPT_TXT="$OUTDIR/05_transcricao.txt"
INSTRUCTIONS_TXT="$OUTDIR/00_roteiro_shadowing.txt"

FF="ffmpeg -loglevel error -y"

# Duração
DURATION=$(ffprobe -loglevel error \
  -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 \
  "$INPUT" | cut -d. -f1)

section "Arquivo: $(basename $INPUT) · Duração: ${DURATION}s · LPF: ${LPF_HZ} Hz @ ${LPF_DB} dB/oct (${LPF_PASSES}x passes) · Compressor: ${COMPRESS_DB} dB"

# -----------------------------------------------------------------------------
# ETAPA 1 — LPF + velocidade reduzida (0.8x)
# -----------------------------------------------------------------------------
section "Etapa 1 · LPF + velocidade 0.8x"
log "Gerando versão lenta com LPF @ ${LPF_HZ} Hz / ${LPF_DB} dB/oct..."

$FF -i "$INPUT" \
  -af "${LPF_CHAIN}atempo=0.8, loudnorm=I=-14:TP=-1:LRA=7" \
  -ar 44100 -ac 1 -c:a flac \
  "$LPF_SLOW"

success "→ $LPF_SLOW"

# -----------------------------------------------------------------------------
# ETAPA 2 — LPF em velocidade normal
# -----------------------------------------------------------------------------
section "Etapa 2 · LPF em velocidade normal"
log "Gerando versão normal com LPF @ ${LPF_HZ} Hz / ${LPF_DB} dB/oct..."

$FF -i "$INPUT" \
  -af "${LPF_CHAIN}loudnorm=I=-14:TP=-1:LRA=7" \
  -ar 44100 -ac 1 -c:a flac \
  "$LPF_NORM"

success "→ $LPF_NORM"

# -----------------------------------------------------------------------------
# ETAPA 3 — Original com compressão leve para estudo
# -----------------------------------------------------------------------------
section "Etapa 3 · Original com compressão (para estudo)"
log "Aplicando compressão dinâmica · threshold: ${COMPRESS_DB} dB..."

$FF -i "$INPUT" \
  -af "acompressor=threshold=${COMPRESS_DB}dB:ratio=3:attack=5:release=80, loudnorm=I=-14:TP=-1:LRA=7" \
  -ar 44100 -ac 1 -c:a flac \
  "$STUDY_FLAC"

success "→ $STUDY_FLAC"

# -----------------------------------------------------------------------------
# ETAPA 4 — Original puro (referência)
# -----------------------------------------------------------------------------
section "Etapa 4 · Convertendo original puro"

$FF -i "$INPUT" \
  -af "loudnorm=I=-14:TP=-1:LRA=7" \
  -ar 44100 -ac 1 -c:a flac \
  "$ORIGINAL_FLAC"

success "→ $ORIGINAL_FLAC"

# -----------------------------------------------------------------------------
# ETAPA 5 — Transcrição com WhisperX
# Usa o áudio original puro para máxima precisão
# Gera .txt limpo, sem timestamps, ideal para leitura lado a lado
# -----------------------------------------------------------------------------
section "Etapa 5 · Transcrição com WhisperX (modelo: ${WHISPER_MODEL})"

if [[ "$WHISPERX_AVAILABLE" == true ]]; then
  log "Transcrevendo com WhisperX... (pode levar alguns minutos)"

  # WhisperX salva os arquivos no --output_dir com o mesmo nome do input
  # Usamos um dir temporário para capturar apenas o .txt gerado
  WHISPER_TMPDIR="$(mktemp -d)"

  WHISPER_LOG="$OUTDIR/whisperx.log"

  whisperx "$ORIGINAL_FLAC" \
    --model "$WHISPER_MODEL" \
    --language en \
    --output_dir "$WHISPER_TMPDIR" \
    --output_format txt \
    --device cpu \
    --compute_type int8 \
    --task transcribe \
    > "$WHISPER_LOG" 2>&1

  # Localizar o .txt gerado e mover para o outdir final
  GENERATED_TXT=$(find "$WHISPER_TMPDIR" -name "*.txt" | head -1)

  if [[ -f "$GENERATED_TXT" ]]; then
    mv "$GENERATED_TXT" "$TRANSCRIPT_TXT"
    rm -rf "$WHISPER_TMPDIR"
    success "→ $TRANSCRIPT_TXT"

    # Exibir prévia das primeiras linhas
    echo ""
    echo -e "  ${BOLD}Prévia da transcrição:${RESET}"
    head -5 "$TRANSCRIPT_TXT" | while IFS= read -r line; do
      echo -e "  ${YELLOW}│${RESET} $line"
    done
    echo ""
  else
    warn "WhisperX não gerou o arquivo .txt esperado."
    warn "Verifique se o modelo '${WHISPER_MODEL}' está disponível."
    rm -rf "$WHISPER_TMPDIR"
  fi

else
  warn "Etapa 5 ignorada — whisperx não está instalado."
  warn "Instale com: pip install whisperx"
fi

# -----------------------------------------------------------------------------
# RESUMO
# -----------------------------------------------------------------------------
section "Arquivos gerados em: $OUTDIR"
echo ""
printf "  ${BOLD}%-4s  %-44s  %s${RESET}\n" "N°" "ARQUIVO" "QUANDO USAR"
printf "  %-4s  %-44s  %s\n"  "--" "-------" "-----------"
printf "  %-4s  %-44s  %s\n"  "00" "$(basename $INSTRUCTIONS_TXT)" "Roteiro completo de pré, shadowing e pós"
printf "  %-4s  %-44s  %s\n"  "01" "$(basename $LPF_SLOW)"     "1ª escuta — ritmo/melodia em câmera lenta"
printf "  %-4s  %-44s  %s\n"  "02" "$(basename $LPF_NORM)"     "2ª escuta — ritmo/melodia em vel. normal"
printf "  %-4s  %-44s  %s\n"  "03" "$(basename $STUDY_FLAC)"    "3ª escuta — original + transcrição aberta"
printf "  %-4s  %-44s  %s\n"  "04" "$(basename $ORIGINAL_FLAC)" "Referência — original sem processamento"
if [[ "$WHISPERX_AVAILABLE" == true && -f "$TRANSCRIPT_TXT" ]]; then
printf "  %-4s  %-44s  %s\n"  "05" "$(basename $TRANSCRIPT_TXT)" "Transcrição gerada pelo WhisperX"
fi
echo ""

section "Roteiro de Pré-Shadowing"
echo ""
echo -e "  ${YELLOW}Passo 1${RESET} — Ouça ${BOLD}01_lpf_lento${RESET} 2–3x"
echo -e "           Não tente entender palavras. Foque em:"
echo -e "           ritmo · pausas · subidas e descidas de entonação"
echo ""
echo -e "  ${YELLOW}Passo 2${RESET} — Leia ${BOLD}05_transcricao.txt${RESET}"
echo -e "           Marque e estude o vocabulário desconhecido"
echo ""
echo -e "  ${YELLOW}Passo 3${RESET} — Ouça ${BOLD}03_original_estudo${RESET} 2x acompanhando a transcrição"
echo ""
echo -e "  ${YELLOW}Passo 4${RESET} — Ouça ${BOLD}02_lpf_normal${RESET} novamente"
echo -e "           Agora você sabe o conteúdo — perceba como a prosódia"
echo -e "           carrega o significado em cada trecho"
echo ""
echo -e "  ${GREEN}→ Pré-Shadowing concluído. Pronto para a sessão de Shadowing.${RESET}"
echo ""

# -----------------------------------------------------------------------------
# ROTEIRO — SHADOWING
# -----------------------------------------------------------------------------
section "Roteiro de Shadowing"
echo ""
echo -e "  ${YELLOW}Warm-up · 5 min${RESET} — Use ${BOLD}02_lpf_normal${RESET}"
echo -e "    Imite só o som, ritmo e melodia. Ignore as palavras."
echo ""
echo -e "  ${YELLOW}Shadowing pleno · 15–20 min${RESET} — Use ${BOLD}04_original_puro${RESET}"
echo -e "    Repita em voz alta com menos de 1s de defasagem."
echo -e "    ${BOLD}Não pare${RESET} se errar — manter o ritmo é prioridade."
echo -e "    ${BOLD}Fale alto${RESET} — sussurrar não treina os músculos da fala."
echo ""
echo -e "  ${YELLOW}Shadowing alternado · 5 min${RESET}"
echo -e "    Alterne a cada 30s: ${BOLD}02_lpf${RESET} → ${BOLD}04_original${RESET} → ${BOLD}02_lpf${RESET}"
echo -e "    O LPF recalibra o ouvido para a prosódia a cada ciclo."
echo ""
echo -e "  ${CYAN}⚠ Não leia a transcrição durante o shadowing.${RESET}"
echo -e "    Ela já cumpriu seu papel no pré. Olhar o texto desvia o"
echo -e "    foco do ouvido para os olhos — siga o falante, não o texto."
echo ""
echo -e "  ${CYAN}Foco sugerido por semana:${RESET}"
echo -e "    S1 → ritmo (você está no tempo certo?)"
echo -e "    S2 → entonação (sua voz sobe/desce nos mesmos pontos?)"
echo -e "    S3 → stress silábico (sílabas certas enfatizadas?)"
echo -e "    S4 → conectividade (palavras grudando como no original?)"
echo ""
echo -e "  ${GREEN}→ Shadowing concluído. Pronto para o Pós-Shadowing.${RESET}"
echo ""

# -----------------------------------------------------------------------------
# ROTEIRO — PÓS-SHADOWING
# -----------------------------------------------------------------------------
section "Roteiro de Pós-Shadowing"
echo ""
echo -e "  ${YELLOW}Passo 1${RESET} — Grave sua voz durante (ou logo após) o shadowing"
echo ""
echo -e "  ${YELLOW}Passo 2${RESET} — Compare sua gravação com ${BOLD}04_original_puro${RESET} em 3 eixos:"
echo -e "    ritmo     → você manteve o tempo e as pausas?"
echo -e "    entonação → a melodia subiu/desceu nos mesmos pontos?"
echo -e "    stress    → as sílabas certas foram enfatizadas?"
echo ""
echo -e "  ${YELLOW}Passo 3${RESET} — Aplique LPF na sua gravação e compare com ${BOLD}02_lpf_normal${RESET}"
echo -e "    Com as palavras fora do caminho, diferenças de prosódia"
echo -e "    ficam expostas e são mais fáceis de identificar."
echo ""
echo -e "  ${YELLOW}Passo 4${RESET} — Registre no diário:"
echo -e "    · O que melhorou em relação à sessão anterior"
echo -e "    · Um padrão prosódico para focar na próxima sessão"
echo ""
echo -e "  ${GREEN}→ Ciclo completo. Bom trabalho.${RESET}"
echo ""

# -----------------------------------------------------------------------------
# ROTEIRO — Gerar arquivo de instruções em texto
# -----------------------------------------------------------------------------
cat > "$INSTRUCTIONS_TXT" << 'EOF'
══════════════════════════════════════════════════════════
 ROTEIRO DE PRÉ-SHADOWING
══════════════════════════════════════════════════════════

Passo 1 — Ouça 01_lpf_lento 2–3x
         Não tente entender palavras. Foque em:
         ritmo · pausas · subidas e descidas de entonação

Passo 2 — Leia 05_transcricao.txt
         Marque e estude o vocabulário desconhecido

Passo 3 — Ouça 03_original_estudo 2x acompanhando a transcrição

Passo 4 — Ouça 02_lpf_normal novamente
         Agora você sabe o conteúdo — perceba como a prosódia
         carrega o significado em cada trecho

→ Pré-Shadowing concluído. Pronto para a sessão de Shadowing.


══════════════════════════════════════════════════════════
 ROTEIRO DE SHADOWING
══════════════════════════════════════════════════════════

Warm-up · 5 min — Use 02_lpf_normal
  Imite só o som, ritmo e melodia. Ignore as palavras.

Shadowing pleno · 15–20 min — Use 04_original_puro
  Repita em voz alta com menos de 1s de defasagem.
  Não pare se errar — manter o ritmo é prioridade.
  Fale alto — sussurrar não treina os músculos da fala.

Shadowing alternado · 5 min
  Alterne a cada 30s: 02_lpf → 04_original → 02_lpf
  O LPF recalibra o ouvido para a prosódia a cada ciclo.

⚠ Não leia a transcrição durante o shadowing.
  Ela já cumpriu seu papel no pré. Olhar o texto desvia o
  foco do ouvido para os olhos — siga o falante, não o texto.

Foco sugerido por semana:
  S1 → ritmo (você está no tempo certo?)
  S2 → entonação (sua voz sobe/desce nos mesmos pontos?)
  S3 → stress silábico (sílabas certas enfatizadas?)
  S4 → conectividade (palavras grudando como no original?)

→ Shadowing concluído. Pronto para o Pós-Shadowing.


══════════════════════════════════════════════════════════
 ROTEIRO DE PÓS-SHADOWING
══════════════════════════════════════════════════════════

Passo 1 — Grave sua voz durante (ou logo após) o shadowing

Passo 2 — Compare sua gravação com 04_original_puro em 3 eixos:
  ritmo     → você manteve o tempo e as pausas?
  entonação → a melodia subiu/desceu nos mesmos pontos?
  stress    → as sílabas certas foram enfatizadas?

Passo 3 — Aplique LPF na sua gravação e compare com 02_lpf_normal
  Com as palavras fora do caminho, diferenças de prosódia
  ficam expostas e são mais fáceis de identificar.

Passo 4 — Registre no diário:
  · O que melhorou em relação à sessão anterior
  · Um padrão prosódico para focar na próxima sessão

→ Ciclo completo. Bom trabalho.
EOF

success "→ $INSTRUCTIONS_TXT"

success "Script finalizado com sucesso."
