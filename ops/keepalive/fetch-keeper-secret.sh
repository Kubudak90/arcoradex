#!/bin/bash
# fetch-keeper-secret.sh
# systemd ExecStartPre: pull keeper key from Vault into a tmpfs EnvironmentFile.
# Cleaned up by ExecStopPost in the unit file.
#
# Inputs:
#   /home/arcora/.vault-creds/role_id     (chmod 400)
#   /home/arcora/.vault-creds/secret_id   (chmod 400)
# Env:
#   KEEPER_TENANT    — "arcoradex" (set per systemd unit via Environment=)
#   KEEPER_ENV_PATH  — destination env file (set per systemd unit via Environment=);
#                      defaults to /run/arcora/keeper.env for backwards compatibility.
#                      H-8 (audit 2026-05-24): each service must use a distinct path
#                      so co-scheduled units do not race each other's ExecStopPost
#                      cleanup of a shared file.
# Output:
#   $KEEPER_ENV_PATH  (mode 600, owned arcora:arcora) containing:
#     KEEPER_PRIMARY_KEY=0x...     (primary-feed writer; H-2)
#     KEEPER_SECONDARY_KEY=0x...   (secondary-feed writer; H-2, MUST differ)
#     KEEPER_PRIVATE_KEY=0x...     (back-compat alias = primary; used by
#                                   guard-record.mjs which signs the
#                                   permissionless record() with the primary EOA)
#
# H-2 (audit 2026-05-31): the two-source oracle requires the PRIMARY and
# SECONDARY feeds to be written by SEPARATE keys, mirroring the on-chain
# MigrateSecondaryWriters split (KEEPER_ADDRESS vs KEEPER_SECONDARY). This script
# now pulls BOTH keys from Vault and validates they differ.

set -euo pipefail
set +x   # explicitly disable trace so no inherited debug shell setting can leak secrets

export VAULT_ADDR="http://127.0.0.1:8200"

ROLE_ID="$(cat /home/arcora/.vault-creds/role_id)"
SECRET_ID="$(cat /home/arcora/.vault-creds/secret_id)"

# Pass secret_id via stdin (vault's "=-" stdin convention) so it never appears
# in /proc/<pid>/cmdline. role_id is not a bearer credential and stays on argv.
VAULT_TOKEN="$(printf '%s' "$SECRET_ID" | vault write -field=token \
    auth/approle/login role_id="$ROLE_ID" secret_id=-)"
export VAULT_TOKEN
unset SECRET_ID   # cleared from env once exchanged for a token

TENANT="${KEEPER_TENANT:-arcoradex}"
ENV_PATH="${KEEPER_ENV_PATH:-/run/arcora/keeper.env}"

# H-2: pull BOTH keys. PRIMARY accepts the new KEEPER_PRIMARY_KEY field and
# falls back to the legacy KEEPER_PRIVATE_KEY field for back-compat on Vault
# secrets written before the split. SECONDARY is required.
PRIMARY_KEY="$(vault kv get -field=KEEPER_PRIMARY_KEY "kv/arcora/keeper-${TENANT}" 2>/dev/null || true)"
if [[ -z "$PRIMARY_KEY" ]]; then
    PRIMARY_KEY="$(vault kv get -field=KEEPER_PRIVATE_KEY "kv/arcora/keeper-${TENANT}")"
fi
SECONDARY_KEY="$(vault kv get -field=KEEPER_SECONDARY_KEY "kv/arcora/keeper-${TENANT}")"

# Validate the fetched key shapes. A silent Vault failure that returns an empty
# or garbled value must fail loudly here, not later in the Node process.
if [[ ! "$PRIMARY_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "fetch-keeper-secret: primary key (KEEPER_PRIMARY_KEY/KEEPER_PRIVATE_KEY) from Vault is not a 0x-prefixed 64-hex string" >&2
    exit 2
fi
if [[ ! "$SECONDARY_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "fetch-keeper-secret: KEEPER_SECONDARY_KEY from Vault is not a 0x-prefixed 64-hex string" >&2
    exit 2
fi
# H-2: the two keys MUST differ (case-insensitive) — identical keys collapse the
# two-source oracle to a single writer, the exact defect the split fixes.
if [[ "${PRIMARY_KEY,,}" == "${SECONDARY_KEY,,}" ]]; then
    echo "fetch-keeper-secret: KEEPER_PRIMARY_KEY must differ from KEEPER_SECONDARY_KEY (H-2)" >&2
    exit 2
fi

# /run/arcora is created by systemd via RuntimeDirectory=arcora in the unit file.
# When this script is invoked manually, the operator must pre-create /run/arcora.

umask 077
cat > "$ENV_PATH" <<EOF
KEEPER_PRIMARY_KEY=$PRIMARY_KEY
KEEPER_SECONDARY_KEY=$SECONDARY_KEY
KEEPER_PRIVATE_KEY=$PRIMARY_KEY
EOF
chown arcora:arcora "$ENV_PATH"
chmod 600 "$ENV_PATH"

# Revoke the short-lived AppRole token; ignore failures (cleanup is best-effort
# and must not block the systemd unit on a transient Vault hiccup).
vault token revoke -self >/dev/null 2>&1 || true

unset VAULT_TOKEN PRIMARY_KEY SECONDARY_KEY
