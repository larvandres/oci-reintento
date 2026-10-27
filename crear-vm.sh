#!/usr/bin/env bash
# Intenta crear la VM ARM gratis (A1.Flex, Ubuntu 24.04) en Oracle Cloud São Paulo.
# Prueba 2 OCPU / 12 GB y 1 OCPU / 6 GB (la chica a veces entra cuando la grande no; después se agranda).
# Rota los 3 fault domains: Oracle elige uno solo si no se le dice, y si ese está lleno falla aunque otro
# tenga lugar; pidiendo FD-1/2/3 explícitamente se atrapa capacidad que si no se perdería.
# Cada minuto consulta el reporte de capacidad (tarda segundos, no crea nada) y pide la VM apenas hay lugar;
# igual hace un pedido real cada CADA_LAUNCH segundos, por si el reporte se equivoca o no hay permiso para pedirlo.
# Uso: crear-vm.sh [minutos]. Sale con 0 si la creó (o si ya existe).
export SUPPRESS_LABEL_WARNING=True
OCI="${OCI:-oci}"
T=ocid1.tenancy.oc1..aaaaaaaahh4mc6kabj2nr5wm56lsa4b4ie2jh4qsmdiocawqiwvcqziqgwsq
AD="MoLZ:SA-SAOPAULO-1-AD-1"
IMG=ocid1.image.oc1.sa-saopaulo-1.aaaaaaaaqqxqqfkhlzjcneto533jgu7ey6nzlzlpt5kuh6cqtbldhy2bu2hq
SSH_KEY="${SSH_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFjZ842cAFtZ9t7B4kEsavbPLHzdDBqpW6IM4tLksYV+}"
FIN=$(( $(date +%s) + ${1:-20} * 60 ))
CADA_REPORTE=60; CADA_LAUNCH="${CADA_LAUNCH:-600}"

# La API a veces da 401 de forma intermitente: reintentar esos
oci_r() { local out; for _ in 1 2 3 4 5 6; do out=$("$OCI" "$@" 2>&1); grep -q NotAuthenticated <<<"$out" || { echo "$out"; return; }; sleep 10; done; echo "$out"; }

ya=$(oci_r compute instance list -c $T --display-name addon-stremio --query 'data[?"lifecycle-state"!=`TERMINATED`].id | [0]' --raw-output)
if [[ "$ya" == ocid1.* ]]; then echo "Ya existe: $ya"; exit 0; fi

SUBNET=$(oci_r network subnet list -c $T --query 'data[0].id' --raw-output)
TAMANOS=('{"ocpus":2,"memoryInGBs":12}' '{"ocpus":1,"memoryInGBs":6}')
FDS=(FAULT-DOMAIN-1 FAULT-DOMAIN-2 FAULT-DOMAIN-3)

# Render del cloud-init: mete el deploy key (en base64) y los datos de DuckDNS en la plantilla.
# Sin SNIFF_DEPLOY_KEY/DUCKDNS_* la VM se crea igual pero sin arrancar el addon (útil para probar).
AQUI="$(cd "$(dirname "$0")" && pwd)"
USER_DATA=""
if [ -n "$SNIFF_DEPLOY_KEY" ] && [ -n "$DUCKDNS_DOMAIN" ] && [ -n "$DUCKDNS_TOKEN" ]; then
    DEPLOY_B64=$(printf '%s' "$SNIFF_DEPLOY_KEY" | base64 -w0)
    USER_DATA="$AQUI/cloud-init.rendered.yaml"
    DEPLOY_B64="$DEPLOY_B64" DUCKDNS_DOMAIN="$DUCKDNS_DOMAIN" DUCKDNS_TOKEN="$DUCKDNS_TOKEN" \
    python3 - "$AQUI/cloud-init.yaml" "$USER_DATA" <<'PY'
import os,sys
t=open(sys.argv[1]).read()
for k in ("DEPLOY_B64","DUCKDNS_DOMAIN","DUCKDNS_TOKEN"): t=t.replace("@%s@"%k, os.environ[k])
open(sys.argv[2],"w").write(t)
PY
    echo "cloud-init listo (DuckDNS: ${DUCKDNS_DOMAIN}.duckdns.org)"
else
    echo "AVISO: faltan SNIFF_DEPLOY_KEY/DUCKDNS_DOMAIN/DUCKDNS_TOKEN; la VM se crea sin cloud-init"
fi

# Imprime el primer tamaño con lugar según el reporte, "no" si no hay ninguno (cualquier otro estado:
# OUT_OF_HOST_CAPACITY, HARDWARE_NOT_SUPPORTED…), "error: …" si no se pudo consultar
reporte() {
    local out
    out=$(oci_r compute compute-capacity-report create -c $T --availability-domain "$AD" \
        --shape-availabilities "[{\"instanceShape\":\"VM.Standard.A1.Flex\",\"instanceShapeConfig\":${TAMANOS[0]}},{\"instanceShape\":\"VM.Standard.A1.Flex\",\"instanceShapeConfig\":${TAMANOS[1]}}]" \
        --query 'data."shape-availabilities"[]."availability-status"' --raw-output)
    if [[ "$out" != \[* ]]; then echo "error: $(grep -m1 -o '"message": "[^"]*"' <<<"$out" || echo "$out" | tail -1)"; return; fi
    local i=0
    for e in $(tr -d '[],"' <<<"$out"); do
        [ "$e" = AVAILABLE ] && { echo "${TAMANOS[$i]}"; return; }
        i=$((i + 1))
    done
    echo no
}

# $1 = tamaño (shape-config), $2 = fault domain
lanzar() {
    local out ud=()
    [ -n "$USER_DATA" ] && ud=(--user-data-file "$USER_DATA")
    out=$(oci_r compute instance launch -c $T --availability-domain "$AD" --display-name addon-stremio \
        --shape VM.Standard.A1.Flex --shape-config "$1" --fault-domain "$2" \
        --image-id $IMG --subnet-id "$SUBNET" --assign-public-ip true --boot-volume-size-in-gbs 50 \
        --metadata "{\"ssh_authorized_keys\":\"$SSH_KEY\"}" "${ud[@]}" \
        --query 'data.{id:id,estado:"lifecycle-state"}')
    if grep -q '"id"' <<<"$out"; then echo "$(date '+%F %T') CREADA ($1 $2): $out"; exit 0; fi
    echo "$(date '+%F %T') pedido ($1 $2): $(grep -m1 -o '"message": "[^"]*"' <<<"$out" || echo "$out" | tail -3)"
}

# El reporte dice que hay lugar en el AD pero no en qué fault domain: probar los 3
lanzar_fds() { local fd; for fd in "${FDS[@]}"; do lanzar "$1" "$fd"; done; }

n=0; ultimo=0; con_reporte=1; errores=0
while [ "$(date +%s)" -lt "$FIN" ]; do
    if [ "$con_reporte" = 1 ]; then
        r=$(reporte)
        case "$r" in
            # Un error suelto (500, 429…) no apaga el reporte: solo 4 seguidos (p. ej. falta de permiso)
            error:*) errores=$((errores + 1))
                if [ "$errores" -ge 4 ]; then echo "$(date '+%F %T') sin reporte de capacidad ($r): sigo solo con pedidos"; con_reporte=0
                else echo "$(date '+%F %T') falló el reporte ($r), reintento en un minuto"; fi ;;
            no) errores=0; echo "$(date '+%F %T') reporte: sin lugar" ;;
            *) errores=0; echo "$(date '+%F %T') el reporte dice que hay lugar: $r"; lanzar_fds "$r"; ultimo=$(date +%s) ;;
        esac
    fi
    if [ $(( $(date +%s) - ultimo )) -ge "$CADA_LAUNCH" ]; then
        # pedido forzado rotando tamaño y fault domain (6 combinaciones: 2 tamaños x 3 FD)
        lanzar "${TAMANOS[$(( n % 2 ))]}" "${FDS[$(( n % 3 ))]}"; n=$((n + 1)); ultimo=$(date +%s)
    fi
    # Sin reporte, pedidos seguidos con 30 s de pausa (como antes); con reporte, un vistazo por minuto
    if [ "$con_reporte" = 1 ]; then sleep $CADA_REPORTE; else sleep 30; ultimo=0; fi
done
echo "$(date '+%F %T') sin lugar en esta corrida ($n pedidos)"
exit 1
