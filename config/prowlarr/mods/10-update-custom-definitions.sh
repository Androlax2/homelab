#!/bin/bash
# --- Mise à jour des définitions personnalisées Prowlarr ---
echo "[CustomDefs] Téléchargement de la définition YggAPI..."

# Path à l'intérieur du container Prowlarr, ne pas modifier
DEST="/config/Definitions/Custom"

# Gist URL (version download), épinglée sur une révision : une modification du gist
# ne change rien ici tant que ce hash n'est pas mis à jour à la main.
URL="https://gist.githubusercontent.com/Clemv95/8bfded23ef23ec78f6678896f42a2b60/raw/f1c073f1994ab9c5c13ab68fa463ac2c862299c8/ygg-api-download.yml"

mkdir -p "$DEST"

echo "Download ygg-api-download.yml"
if curl -fsSL "$URL" -o "$DEST/ygg-api-download.yml"; then
    # abc = l'utilisateur LinuxServer, deja remappe sur PUID/PGID quand ce script tourne
    chown abc:abc "$DEST/ygg-api-download.yml"
    chmod 644 "$DEST/ygg-api-download.yml"
    echo "OK"
    echo "[CustomDefs] Terminé avec succès."
else
    echo "Erreur de téléchargement"
    echo "[CustomDefs] Échec - vérifiez votre connexion internet."
    exit 1
fi