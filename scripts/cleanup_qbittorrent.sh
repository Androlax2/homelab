#!/usr/bin/env bash
set -euo pipefail
trap 'printf "%s ERREUR FATALE ligne %s (exit code %s)\n" "$(date '\''+%Y-%m-%d %H:%M:%S'\'')" "$LINENO" "$?" >&2' ERR

# ============================================================
# Orphaned torrent cleanup for qBittorrent (hardlink-based *arr setup)
#
# Un fichier est "orphelin" si :
#   - c'est une video (.mkv/.mp4/.avi)
#   - il n'a qu'un seul hardlink (pas importe dans la mediatheque)
#   - il est plus vieux que MIN_AGE_DAYS  <- protege les imports en cours
#   - il n'apparait pas dans la queue Sonarr/Radarr
#
# Matching torrent : on remonte l'arborescence depuis le fichier jusqu'a
# DOWNLOADS_PATH en comparant chaque chemin au contenu des torrents (gere les
# season packs imbriques du type <torrent>/<episode>/<episode>.mkv).
#
# Usage :
#   ./cleanup_qbittorrent.sh              -> execution reelle
#   DRY_RUN=1 ./cleanup_qbittorrent.sh    -> simulation, rien n'est supprime
# ============================================================

# ---------- Config ----------
QBITTORRENT_CONTAINER="qbittorrent"
QBITTORRENT_URL="http://localhost:8080"
DOWNLOADS_PATH="/downloads"          # chemin VU DEPUIS le container qbittorrent
MIN_AGE_DAYS=7                       # ne touche pas aux fichiers plus recents
DRY_RUN="${DRY_RUN:-0}"

# Fichiers orphelins SANS torrent correspondant (vrais dechets) :
# 0 = les laisser en place (log seulement), 1 = les supprimer s'ils ont
# plus de PURGE_UNMATCHED_AGE_DAYS jours.
PURGE_UNMATCHED=1
PURGE_UNMATCHED_AGE_DAYS=30

# Identifiants de l'interface web de qBittorrent (stacks/media/.env).
QBITTORRENT_USERNAME="${QBITTORRENT_USERNAME:?QBITTORRENT_USERNAME manquant (stacks/media/.env)}"
QBITTORRENT_PASSWORD="${QBITTORRENT_PASSWORD:?QBITTORRENT_PASSWORD manquant (stacks/media/.env)}"

# Check des queues *arr avant suppression. Cles obligatoires (stacks/media/.env) :
# sans elles, un import en cours pourrait etre supprime.
SONARR_URL="http://localhost:8989"
SONARR_API_KEY="${SONARR_API_KEY:?SONARR_API_KEY manquant (stacks/media/.env)}"
RADARR_URL="http://localhost:7878"
RADARR_API_KEY="${RADARR_API_KEY:?RADARR_API_KEY manquant (stacks/media/.env)}"

umask 077
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
QBITTORRENT_COOKIES="$WORK_DIR/cookies"

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

# Ouvre une session sur l'API de qBittorrent (cookie dans QBITTORRENT_COOKIES).
# Le Referer est obligatoire : qBittorrent refuse un login dont le Referer
# n'est pas sa propre adresse.
qbittorrent_login() {
    local answer
    # Mot de passe lu depuis un fichier : en argument, il serait visible dans `ps`.
    printf '%s' "$QBITTORRENT_PASSWORD" > "$WORK_DIR/password"
    answer=$(curl -sf -c "$QBITTORRENT_COOKIES" -H "Referer: $QBITTORRENT_URL" \
        --data-urlencode "username=$QBITTORRENT_USERNAME" \
        --data-urlencode "password@$WORK_DIR/password" \
        "$QBITTORRENT_URL/api/v2/auth/login") || answer=""
    [ "$answer" = "Ok." ]
}

# ---------- 1. Snapshot des torrents qBittorrent (paires chemin<TAB>hash) ----------
if ! qbittorrent_login; then
    log "ERREUR: login qBittorrent refuse ($QBITTORRENT_URL). Arret, rien n'a ete supprime."
    exit 1
fi

log "Recuperation de la liste des torrents..."
if ! RAW_INFO=$(curl -sf -b "$QBITTORRENT_COOKIES" "$QBITTORRENT_URL/api/v2/torrents/info"); then
    log "ERREUR: liste des torrents injoignable ($QBITTORRENT_URL)"
    exit 1
fi

# content_path = le dossier du torrent, ou son fichier s'il n'en a qu'un.
# Un torrent sans dossier a lui (content_path = save_path) est ecarte : son
# chemin est le dossier de telechargement, ou vivent aussi les fichiers des
# autres torrents, et il correspondrait a tous leurs orphelins.
if ! TORRENT_MAP=$(printf '%s\n' "$RAW_INFO" | jq -r '
    .[]
    | (.content_path | rtrimstr("/")) as $content_path
    | select($content_path != (.save_path | rtrimstr("/")))
    | "\($content_path)\t\(.hash)"'); then
    log "ERREUR: reponse de qBittorrent non parsable. Reponse brute:"
    printf '%s\n' "$RAW_INFO" | head -20
    exit 1
fi

# Sans aucun torrent, chaque fichier serait un dechet a purger : on s'arrete.
if [ -z "$TORRENT_MAP" ]; then
    log "ERREUR: qBittorrent ne liste aucun torrent utilisable. Arret, rien n'a ete supprime."
    exit 1
fi
log "$(printf '%s\n' "$TORRENT_MAP" | wc -l) torrents actifs."

# ---------- 2. Queues *arr (protection des imports en attente) ----------
if ! ARR_QUEUE=$(fetch_arr_queues); then
    log "ERREUR: impossible de lire les queues Sonarr/Radarr. Arret, rien n'a ete supprime."
    exit 1
fi
[ -n "$ARR_QUEUE" ] && log "Queue *arr recuperee ($(printf '%s\n' "$ARR_QUEUE" | grep -c .) items)."

# Hash du torrent dont le contenu est EXACTEMENT ce chemin. Jamais de
# correspondance par prefixe : le dossier "Dune" trouverait le torrent
# "Dune.Part.Two..." et on supprimerait les donnees d'un autre torrent.
# $1 = chemin d'un fichier ou d'un dossier
find_torrent_hash() {
    printf '%s\n' "$TORRENT_MAP" | candidate="$1" awk -F'\t' \
        '$1 == ENVIRON["candidate"] { print $2; exit }'
}

# Remonte l'arborescence depuis le fichier jusqu'a DOWNLOADS_PATH (exclu) en
# cherchant un torrent pour chaque chemin. Gere les season packs imbriques.
# $1 = chemin complet du fichier. Affiche "hash<TAB>chemin" si trouve.
find_torrent_for_file() {
    local current="$1"
    while [ -n "$current" ] && [ "$current" != "$DOWNLOADS_PATH" ] && [ "$current" != "/" ]; do
        local hash
        hash=$(find_torrent_hash "$current")
        if [ -n "$hash" ]; then
            printf '%s\t%s' "$hash" "$current"
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

    torrent_hash=""
    match_result=$(find_torrent_for_file "$file" || true)
    [ -n "$match_result" ] && {
        torrent_hash="${match_result%%$'\t'*}"
        log "  -> Match: ${match_result#*$'\t'}"
    }

    if [ -n "$torrent_hash" ]; then
        log "  -> Suppression torrent + data (hash: $torrent_hash)"
        run curl -sf -o /dev/null -b "$QBITTORRENT_COOKIES" \
            --data-urlencode "hashes=$torrent_hash" --data-urlencode "deleteFiles=true" \
            "$QBITTORRENT_URL/api/v2/torrents/delete"
        removed=$((removed + 1))
    elif [ "$PURGE_UNMATCHED" = "1" ]; then
        # Vrai dechet : aucun torrent, fichier vieux -> suppression directe
        old_check=$(docker exec "$QBITTORRENT_CONTAINER" find "$file" -mtime "+${PURGE_UNMATCHED_AGE_DAYS}" 2>/dev/null || true)
        if [ -n "$old_check" ]; then
            log "  -> Aucun torrent + age > ${PURGE_UNMATCHED_AGE_DAYS}j : suppression du fichier"
            run docker exec "$QBITTORRENT_CONTAINER" rm -f "$file"
            purged=$((purged + 1))
        else
            log "  -> Aucun torrent mais trop recent pour purge. Laisse en place."
            skipped=$((skipped + 1))
        fi
    else
        log "  -> Aucun torrent correspondant. Fichier laisse en place (PURGE_UNMATCHED=0)."
        skipped=$((skipped + 1))
    fi
done < <(docker exec "$QBITTORRENT_CONTAINER" find "$DOWNLOADS_PATH" -type f \
            \( -name '*.mkv' -o -name '*.mp4' -o -name '*.avi' \) -mtime "+${MIN_AGE_DAYS}" \
            -links 1  -print0)

log "Termine. Torrents supprimes: $removed | Fichiers purges: $purged | Ignores: $skipped"
if [ "$DRY_RUN" = "1" ]; then
    log "(mode DRY-RUN : rien n'a ete supprime)"
fi
