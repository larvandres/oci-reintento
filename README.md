# oci-reintento

Reintenta crear una VM ARM gratis (Always Free) en Oracle Cloud São Paulo hasta que haya capacidad
("Out of host capacity"). Corre en GitHub Actions cada 20 minutos; cuando la crea, abre un issue y se apaga solo.

Secretos del repo: `OCI_USER`, `OCI_FINGERPRINT`, `OCI_KEY` (usuario de Oracle con permisos limitados a crear VMs).
