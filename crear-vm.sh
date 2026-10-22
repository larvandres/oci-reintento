#!/usr/bin/env bash
# Intenta crear la VM ARM gratis (A1.Flex 2 OCPU / 12 GB, Ubuntu 24.04) en Oracle Cloud São Paulo.
# Uso: crear-vm.sh [intentos] [segundos entre intentos]. Sale con 0 si la creó (o si ya existe).
export SUPPRESS_LABEL_WARNING=True
OCI="${OCI:-oci}"
T=ocid1.tenancy.oc1..aaaaaaaahh4mc6kabj2nr5wm56lsa4b4ie2jh4qsmdiocawqiwvcqziqgwsq
AD="MoLZ:SA-SAOPAULO-1-AD-1"
IMG=ocid1.image.oc1.sa-saopaulo-1.aaaaaaaaqqxqqfkhlzjcneto533jgu7ey6nzlzlpt5kuh6cqtbldhy2bu2hq
SSH_KEY="${SSH_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFjZ842cAFtZ9t7B4kEsavbPLHzdDBqpW6IM4tLksYV+}"
INTENTOS="${1:-1}"; ESPERA="${2:-60}"

# La API a veces da 401 de forma intermitente: reintentar esos
oci_r() { local out; for _ in 1 2 3 4 5 6; do out=$("$OCI" "$@" 2>&1); grep -q NotAuthenticated <<<"$out" || { echo "$out"; return; }; sleep 10; done; echo "$out"; }

ya=$(oci_r compute instance list -c $T --display-name addon-stremio --query 'data[?"lifecycle-state"!=`TERMINATED`].id | [0]' --raw-output)
if [[ "$ya" == ocid1.* ]]; then echo "Ya existe: $ya"; exit 0; fi

SUBNET=$(oci_r network subnet list -c $T --query 'data[0].id' --raw-output)
for n in $(seq 1 "$INTENTOS"); do
    out=$(oci_r compute instance launch -c $T --availability-domain "$AD" --display-name addon-stremio \
        --shape VM.Standard.A1.Flex --shape-config '{"ocpus":2,"memoryInGBs":12}' \
        --image-id $IMG --subnet-id "$SUBNET" --assign-public-ip true --boot-volume-size-in-gbs 50 \
        --metadata "{\"ssh_authorized_keys\":\"$SSH_KEY\"}" \
        --query 'data.{id:id,estado:"lifecycle-state"}')
    if grep -q '"id"' <<<"$out"; then echo "$(date '+%F %T') CREADA: $out"; exit 0; fi
    echo "$(date '+%F %T') intento $n: $(grep -m1 -o '"message": "[^"]*"' <<<"$out" || echo "$out" | tail -3)"
    [ "$n" -lt "$INTENTOS" ] && sleep "$ESPERA"
done
exit 1
