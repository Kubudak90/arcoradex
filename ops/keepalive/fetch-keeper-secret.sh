#!/bin/bash
# fetch-keeper-secret.sh
# systemd ExecStartPre: pull keeper key from Vault into a tmpfs EnvironmentFile
# for the multi-feed-push.mjs run. Cleaned up by ExecStopPost in the unit file.
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
export VAULT_ADDR="http://127.0.0.1:8200"

ROLE_ID="$(cat /home/arcora/.vault-creds/role_id)"
SECRET_ID="$(cat /home/arcora/.vault-creds/secret_id)"

VAULT_TOKEN="$(vault write -field=token auth/approle/login \
    role_id="$ROLE_ID" secret_id="$SECRET_ID")"
export VAULT_TOKEN

TENANT="${KEEPER_TENANT:-arcoradex}"
KEEPER_KEY="$(vault kv get -field=KEEPER_PRIVATE_KEY "kv/arcora/keeper-${TENANT}")"

# /run/arcora is created by systemd via RuntimeDirectory=arcora in the unit file.
# When this script is invoked manually (e.g. plan Step 8.7), the operator must
# pre-create /run/arcora as the arcora user is not allowed to mkdir under /run.

umask 077
cat > /run/arcora/keeper.env <<EOF
KEEPER_PRIVATE_KEY=$KEEPER_KEY
EOF
chown arcora:arcora /run/arcora/keeper.env
chmod 600 /run/arcora/keeper.env

unset VAULT_TOKEN KEEPER_KEY
