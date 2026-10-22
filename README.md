# oci-reintento

Reintenta crear una VM ARM gratis (Always Free) en Oracle Cloud São Paulo hasta que haya capacidad
("Out of host capacity"), alternando 2 OCPU / 12 GB y 1 OCPU / 6 GB: se queda con la primera que salga. Consulta el reporte de capacidad
de Oracle cada minuto (necesita `manage compute-capacity-reports` para el grupo `robot-vm`; sin eso, pide la VM cada 30 s).
Corre en GitHub Actions (corridas de hasta 85 min, disparadas cada 20); cuando la crea, abre un issue y se apaga solo.

Secretos del repo: `OCI_USER`, `OCI_FINGERPRINT`, `OCI_KEY` (usuario de Oracle con permisos limitados a crear VMs).
