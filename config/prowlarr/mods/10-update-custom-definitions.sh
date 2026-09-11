#!/bin/bash
# --- Mise à jour des définitions personnalisées Prowlarr ---
echo "[CustomDefs] Téléchargement de la définition YggAPI..."

# À personnaliser selon votre configuration :
PUID=1028
PGID=100

# Path à l'intérieur du container Prowlarr, ne pas modifier
DEST="/config/Definitions/Custom"

# Gist URL (version download)
URL="https://gist.githubusercontent.com/Clemv95/8bfded23ef23ec78f6678896f42a2b60/raw/ygg-api-download.yml"

mkdir -p "$DEST"

echo "Download ygg-api-download.yml"
if curl -fsSL "$URL" -o "$DEST/ygg-api-download.yml"; then
    chown "$PUID:$PGID" "$DEST/ygg-api-download.yml"
    chmod 644 "$DEST/ygg-api-download.yml"
    echo "OK"
    echo "[CustomDefs] Terminé avec succès."
else
    echo "Erreur de téléchargement"
    echo "[CustomDefs] Échec - vérifiez votre connexion internet."
    exit 1
fi