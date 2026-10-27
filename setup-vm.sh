#!/usr/bin/env bash
# Setup único para que la VM arranque sola con el addon y HTTPS. Correr desde la PC del usuario.
# Hace lo que Claude no puede (toca credenciales y la red): deploy key + secrets + puertos de la VCN.
# Requisitos: gh logueado (larvandres), oci configurado (~/.oci/config con acceso total), una cuenta DuckDNS.
set -euo pipefail

REPO_ADDON=larvandres/sniff          # repo privado del addon
REPO_REINTENTO=larvandres/oci-reintento
SL=ocid1.securitylist.oc1.sa-saopaulo-1.aaaaaaaavqbrcffsupdofabsrm7fqyqnmcy6awdpydl4nveekbjqnpcfyafq
OCI="${OCI:-$HOME/.local/bin/oci}"
export SUPPRESS_LABEL_WARNING=True

# Toma los valores de variables de entorno; si faltan, los pide.
[ -n "${DUCKDNS_DOMAIN:-}" ] || read -rp "Subdominio DuckDNS (solo el nombre, sin .duckdns.org): " DUCKDNS_DOMAIN
[ -n "${DUCKDNS_TOKEN:-}" ]  || { read -rsp "Token DuckDNS: " DUCKDNS_TOKEN; echo; }

# 1. Deploy key de solo lectura: la VM clona el repo privado sin tu cuenta
echo "== Deploy key =="
TMP=$(mktemp -d)
ssh-keygen -t ed25519 -N '' -C 'oci-vm-deploy-sniff' -f "$TMP/key" >/dev/null
gh repo deploy-key add "$TMP/key.pub" -R "$REPO_ADDON" -t "oci-vm-addon" || \
  echo "  (si ya existe una 'oci-vm-addon', borrala en Settings > Deploy keys y reintentá)"

# 2. Secrets en el repo del reintento
echo "== Secrets =="
gh secret set SNIFF_DEPLOY_KEY -R "$REPO_REINTENTO" < "$TMP/key"
gh secret set DUCKDNS_DOMAIN   -R "$REPO_REINTENTO" --body "$DUCKDNS_DOMAIN"
gh secret set DUCKDNS_TOKEN    -R "$REPO_REINTENTO" --body "$DUCKDNS_TOKEN"
rm -rf "$TMP"

# 3. Abrir 80/443 en la VCN (ingreso). Se agregan sin tocar las reglas existentes.
echo "== Puertos 80/443 en la VCN =="
TMP_SL=$(mktemp)
"$OCI" network security-list get --security-list-id "$SL" > "$TMP_SL"
python3 - "$TMP_SL" <<'PY' > /tmp/ingress.json
import json,sys
d=json.load(open(sys.argv[1]))['data']['ingress-security-rules']
out=[]
have=set()
for r in d:
    nr={'protocol':r['protocol'],'source':r['source'],'isStateless':r.get('is-stateless',False)}
    if r.get('tcp-options'):
        pr=r['tcp-options']['destination-port-range']; nr['tcpOptions']={'destinationPortRange':pr}
        have.add(pr.get('min'))
    out.append(nr)
for p in (80,443):
    if p not in have:
        out.append({'protocol':'6','source':'0.0.0.0/0','isStateless':False,
                    'tcpOptions':{'destinationPortRange':{'min':p,'max':p}}})
json.dump(out,open('/tmp/ingress.json','w'))
PY
"$OCI" network security-list update --security-list-id "$SL" \
  --ingress-security-rules file:///tmp/ingress.json --force >/dev/null
rm -f "$TMP_SL" /tmp/ingress.json
echo "Puertos 80/443 abiertos."

echo
echo "Listo. Ya podés disparar el reintento:"
echo "  gh workflow enable reintento.yml -R $REPO_REINTENTO"
echo "  gh workflow run    reintento.yml -R $REPO_REINTENTO"
echo "Cuando cree la VM, el issue te llega por mail con la URL https://$DUCKDNS_DOMAIN.duckdns.org/manifest.json"
