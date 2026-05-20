#!/bin/bash
# fetch-keeper-secret.sh
# systemd ExecStartPre: pull keeper key from Vault into a tmpfs EnvironmentFile.
# Cleaned up by ExecStopPost in the unit file.
#
# Inputs:
#   /home/arcora/.vault-creds/role_id     (chmod 400)
#   /home/arcora/.vault-creds/secret_id   (chmod 400)
# Env:
#   KEEPER_TENANT  — "arcoradex" (set per systemd unit via Environment=)
# Output:
#   /run/arcora/keeper.env  (mode 600, owned arcora:arcora)
#     containing: KEEPER_PRIVATE_KEY=0x...

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
KEEPER_KEY="$(vault kv get -field=KEEPER_PRIVATE_KEY "kv/arcora/keeper-${TENANT}")"

# Validate the fetched key shape. A silent Vault failure that returns an empty
# or garbled value must fail loudly here, not later in the Node process.
if [[ ! "$KEEPER_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "fetch-keeper-secret: KEEPER_PRIVATE_KEY from Vault is not a 0x-prefixed 64-hex string" >&2
    exit 2
fi

# /run/arcora is created by systemd via RuntimeDirectory=arcora in the unit file.
# When this script is invoked manually, the operator must pre-create /run/arcora.

umask 077
cat > /run/arcora/keeper.env <<EOF
KEEPER_PRIVATE_KEY=$KEEPER_KEY
EOF
chown arcora:arcora /run/arcora/keeper.env
chmod 600 /run/arcora/keeper.env

# Revoke the short-lived AppRole token; ignore failures (cleanup is best-effort
# and must not block the systemd unit on a transient Vault hiccup).
vault token revoke -self >/dev/null 2>&1 || true

unset VAULT_TOKEN KEEPER_KEY
