#!/usr/bin/env bash
set -euo pipefail
trap 'printf "%s ERREUR FATALE ligne %s (exit code %s)\n" "$(date '\''+%Y-%m-%d %H:%M:%S'\'')" "$LINENO" "$?" >&2' ERR

# ============================================================
# Orphaned torrent cleanup for Deluge (hardlink-based *arr setup)
#
# Un fichier est "orphelin" si :
#   - c'est une video (.mkv/.mp4/.avi)
#   - il n'a qu'un seul hardlink (pas importe dans la mediatheque)
#   - il est plus vieux que MIN_AGE_DAYS  <- protege les imports en cours
#   - il n'apparait pas dans la queue Sonarr/Radarr
#
# Matching torrent : on remonte l'arborescence depuis le fichier jusqu'a
# DOWNLOADS_PATH en essayant chaque nom de dossier (gere les season packs
# imbriques du type <torrent>/<episode>/<episode>.mkv).
#
# Usage :
#   ./cleanup_deluge.sh              -> execution reelle
#   DRY_RUN=1 ./cleanup_deluge.sh    -> simulation, rien n'est supprime
# ============================================================

# ---------- Config ----------
DELUGE_CONTAINER="deluge"
DOWNLOADS_PATH="/downloads"          # chemin VU DEPUIS le container deluge
MIN_AGE_DAYS=7                       # ne touche pas aux fichiers plus recents
DRY_RUN="${DRY_RUN:-0}"

# Fichiers orphelins SANS torrent correspondant (vrais dechets) :
# 0 = les laisser en place (log seulement), 1 = les supprimer s'ils ont
# plus de PURGE_UNMATCHED_AGE_DAYS jours.
PURGE_UNMATCHED=1
PURGE_UNMATCHED_AGE_DAYS=30

# Check des queues *arr avant suppression. Cles obligatoires (stacks/media/.env) :
# sans elles, un import en cours pourrait etre supprime.
SONARR_URL="http://localhost:8989"
SONARR_API_KEY="${SONARR_API_KEY:?SONARR_API_KEY manquant (stacks/media/.env)}"
RADARR_URL="http://localhost:7878"
RADARR_API_KEY="${RADARR_API_KEY:?RADARR_API_KEY manquant (stacks/media/.env)}"

# ---------- Helpers ----------
log()  { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
run()  { if [ "$DRY_RUN" = "1" ]; then log "[DRY-RUN] $*"; else "$@"; fi; }

# Titres presents dans une queue *arr. Echoue si l'API ne repond pas : sans la
# queue, un import en cours pourrait etre supprime.
# $1 = URL de base, $2 = cle API
fetch_arr_queue() {
    local response
    if ! response=$(curl -sf "${1}/api/v3/queue?pageSize=200" -H "X-Api-Key: ${2}"); then
        log "ERREUR: queue injoignable (${1})" >&2
        return 1
    fi
    printf '%s\n' "$response" | jq -r '.records[].title'
}

# Recupere les noms de fichiers presents dans les queues Sonarr/Radarr
fetch_arr_queues() {
    fetch_arr_queue "$SONARR_URL" "$SONARR_API_KEY" || return 1
    fetch_arr_queue "$RADARR_URL" "$RADARR_API_KEY" || return 1
}

# ---------- 1. Snapshot des torrents Deluge (paires nom<TAB>hash) ----------
# Format de sortie de cette version de deluge-console :
#   [S]   100% Nom.De.La.Release.S01.MULTi.1080p... <hash 40 hex>
#       DL: 24.4 G (0 B) UL: 49.5 G (0 B) ETA: -
log "Recuperation de la liste des torrents..."
RAW_INFO=$(docker exec "$DELUGE_CONTAINER" deluge-console -c /config/ info 2>&1) || {
    log "ERREUR deluge-console:"
    printf '%s\n' "$RAW_INFO"
    exit 1
}

TORRENT_MAP=$(printf '%s\n' "$RAW_INFO" | awk '
    /^\[/ {
        hash = $NF
        name = ""
        for (i = 3; i < NF; i++) name = name (name ? " " : "") $i
        if (hash ~ /^[0-9a-fA-F]{40}$/) print name "\t" hash
    }
')

if [ -z "$TORRENT_MAP" ]; then
    log "ERREUR: sortie deluge-console non parsable. Sortie brute:"
    printf '%s\n' "$RAW_INFO" | head -20
    exit 1
fi
log "$(printf '%s\n' "$TORRENT_MAP" | wc -l) torrents actifs."

# ---------- 2. Queues *arr (protection des imports en attente) ----------
if ! ARR_QUEUE=$(fetch_arr_queues); then
    log "ERREUR: impossible de lire les queues Sonarr/Radarr. Arret, rien n'a ete supprime."
    exit 1
fi
[ -n "$ARR_QUEUE" ] && log "Queue *arr recuperee ($(printf '%s\n' "$ARR_QUEUE" | grep -c .) items)."

# Hash du torrent dont le nom est EXACTEMENT le candidat (insensible a la casse).
# Jamais de correspondance par prefixe : le dossier "Dune" trouverait le torrent
# "Dune.Part.Two..." et on supprimerait les donnees d'un autre torrent.
# $1 = nom candidat (dossier ou fichier sans extension)
find_torrent_hash() {
    printf '%s\n' "$TORRENT_MAP" | candidate="$1" awk -F'\t' \
        'tolower($1) == tolower(ENVIRON["candidate"]) { print $2; exit }'
}

# Remonte l'arborescence depuis le fichier jusqu'a DOWNLOADS_PATH en essayant
# un match torrent sur chaque nom de dossier. Gere les season packs imbriques.
# $1 = chemin complet du fichier. Affiche "hash<TAB>nom_dossier" si trouve.
find_torrent_for_file() {
    local current
    current=$(dirname "$1")
    while [ -n "$current" ] && [ "$current" != "$DOWNLOADS_PATH" ] && [ "$current" != "/" ]; do
        local candidate hash
        candidate=$(basename "$current")
        hash=$(find_torrent_hash "$candidate")
        if [ -n "$hash" ]; then
            printf '%s\t%s' "$hash" "$candidate"
            return 0
        fi
        current=$(dirname "$current")
    done
    return 1
}

# ---------- 3. Scan des fichiers orphelins ----------
log "Scan des fichiers orphelins (age > ${MIN_AGE_DAYS}j, hardlinks = 1)..."
removed=0
purged=0
skipped=0

while IFS= read -r -d '' file; do
    file_name=$(basename "$file")
    file_stem="${file_name%.*}"

    log "Orphelin: $file"

    # Protection : fichier present dans une queue Sonarr/Radarr ?
    if [ -n "$ARR_QUEUE" ]; then
        if printf '%s\n' "$ARR_QUEUE" | grep -qiF "$file_stem"; then
            log "  -> SKIP: present dans la queue Sonarr/Radarr (import en attente)"
            skipped=$((skipped + 1))
            continue
        fi
    fi

    # Matching torrent : d'abord en remontant les dossiers, puis par nom de fichier
    torrent_hash=""
    match_result=$(find_torrent_for_file "$file" || true)
    [ -n "$match_result" ] && {
        torrent_hash="${match_result%%$'\t'*}"
        log "  -> Match par dossier: ${match_result#*$'\t'}"
    }
    if [ -z "$torrent_hash" ]; then
        torrent_hash=$(find_torrent_hash "$file_stem" || true)
        [ -n "$torrent_hash" ] && log "  -> Match par fichier: $file_stem"
    fi

    if [ -n "$torrent_hash" ]; then
        log "  -> Suppression torrent + data (hash: $torrent_hash)"
        run docker exec "$DELUGE_CONTAINER" \
            deluge-console -c /config/ "rm $torrent_hash --remove_data -c"
        removed=$((removed + 1))
    elif [ "$PURGE_UNMATCHED" = "1" ]; then
        # Vrai dechet : aucun torrent, fichier vieux -> suppression directe
        old_check=$(docker exec "$DELUGE_CONTAINER" find "$file" -mtime "+${PURGE_UNMATCHED_AGE_DAYS}" 2>/dev/null || true)
        if [ -n "$old_check" ]; then
            log "  -> Aucun torrent + age > ${PURGE_UNMATCHED_AGE_DAYS}j : suppression du fichier"
            run docker exec "$DELUGE_CONTAINER" rm -f "$file"
            purged=$((purged + 1))
        else
            log "  -> Aucun torrent mais trop recent pour purge. Laisse en place."
            skipped=$((skipped + 1))
        fi
    else
        log "  -> Aucun torrent correspondant. Fichier laisse en place (PURGE_UNMATCHED=0)."
        skipped=$((skipped + 1))
    fi
done < <(docker exec "$DELUGE_CONTAINER" find "$DOWNLOADS_PATH" -type f \
            \( -name '*.mkv' -o -name '*.mp4' -o -name '*.avi' \) -mtime "+${MIN_AGE_DAYS}" \
            -links 1  -print0)

log "Termine. Torrents supprimes: $removed | Fichiers purges: $purged | Ignores: $skipped"
if [ "$DRY_RUN" = "1" ]; then
    log "(mode DRY-RUN : rien n'a ete supprime)"
fi