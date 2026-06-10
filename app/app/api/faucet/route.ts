import { NextResponse } from "next/server";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  isAddress,
  getAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "@arcoralabs/dex-sdk/v2";
import { checkBotId } from "botid/server";
import {
  createCooldownStore,
  checkRateLimit,
  recordClaim,
  rollbackClaim,
  reserveInflight,
  releaseInflight,
  consumeHourlyBudget,
  refundHourlyBudget,
  extractClientIp,
} from "@/lib/faucet-rate-limit";
import { FAUCET_TOKENS } from "@/lib/faucet-tokens";

export const runtime = "nodejs";

const MINT_ABI = parseAbi(["function mint(address to, uint256 amount)"]);

// L-11 (audit 2026-05-31): treat either Node's NODE_ENV or Vercel's VERCEL_ENV
// as the production signal so the fail-closed origin check fires on real
// deploys (Vercel sets VERCEL_ENV) and on any other prod build.
function isProduction(): boolean {
  return process.env.NODE_ENV === "production" || process.env.VERCEL_ENV === "production";
}

// M-3 (audit 2026-05-31): cooldown + in-flight reservation now go through a
// cross-instance store (Upstash Redis when UPSTASH_REDIS_REST_URL/TOKEN are
// set, in-memory fallback otherwise). The store is keyed by both recipient
// address AND client IP, plus a global hourly mint-budget. Reservation uses an
// atomic SET-NX so two concurrent POSTs on different Vercel instances can no
// longer both run the 7-tx mint loop — the previous module-scoped Sets only
// guarded a single instance.
const cooldownStore = createCooldownStore();

interface FaucetSuccess {
  ok: true;
  recipient: `0x${string}`;
  txHashes: Record<string, `0x${string}`>;
}
interface FaucetError {
  ok: false;
  error: string;
  retryAfterSec?: number;
}

export async function POST(req: Request): Promise<NextResponse<FaucetSuccess | FaucetError>> {
  // H-7 (audit 2026-05-24): same-origin enforcement. The browser sends Origin
  // automatically on cross-origin POSTs; rejecting unknown origins blocks the
  // basic cross-site exploit surface even before the BotID signal is read.
  const allowedOrigin = process.env.NEXT_PUBLIC_APP_URL;
  if (allowedOrigin) {
    const origin = req.headers.get("origin");
    const referer = req.headers.get("referer");
    const originOk = origin === allowedOrigin;
    const refererOk = referer != null && referer.startsWith(allowedOrigin);
    if (!originOk && !refererOk) {
      return NextResponse.json(
        { ok: false, error: "Forbidden origin." },
        { status: 403 },
      );
    }
  } else if (isProduction()) {
    // L-11 (audit 2026-05-31): fail CLOSED in production. Previously an unset
    // NEXT_PUBLIC_APP_URL skipped the origin check entirely (fail-open), so a
    // misconfigured prod deploy silently accepted cross-site POSTs. In prod we
    // now reject rather than skip; dev (where the allowlist is normally unset)
    // stays permissive so local testing isn't blocked.
    return NextResponse.json(
      { ok: false, error: "Faucet origin allowlist is not configured." },
      { status: 403 },
    );
  }

  // Vercel BotID — server check first. The matching <BotIdClient> in
  // app/layout.tsx attaches the signed signal on the client side; bots that
  // hit /api/faucet directly (curl, fresh headless browsers) are caught here.
  const { isBot } = await checkBotId();
  if (isBot) {
    return NextResponse.json(
      { ok: false, error: "Request flagged as automated. Open the page in a normal browser and try again." },
      { status: 403 },
    );
  }

  const key = process.env.FAUCET_PRIVATE_KEY;
  if (!key || !key.startsWith("0x")) {
    return NextResponse.json(
      { ok: false, error: "Faucet is not configured (FAUCET_PRIVATE_KEY missing)." },
      { status: 500 },
    );
  }

  let body: { address?: string };
  try {
    body = (await req.json()) as { address?: string };
  } catch {
    return NextResponse.json({ ok: false, error: "Invalid JSON body." }, { status: 400 });
  }

  if (!body.address || !isAddress(body.address)) {
    return NextResponse.json({ ok: false, error: "Invalid recipient address." }, { status: 400 });
  }
  const recipient = getAddress(body.address);

  // Rate limit: per-recipient AND per-IP (cross-instance via the store).
  const ip = extractClientIp(req);
  const rl = await checkRateLimit(cooldownStore, recipient, ip);
  if (!rl.ok) {
    const hours = Math.max(1, Math.ceil(rl.retryAfterSec / 3600));
    const error =
      rl.blockedBy === "ip"
        ? `An address from your network already claimed in the last 24 hours. Try again in ${hours}h.`
        : `You already claimed in the last 24 hours. Try again in ${hours}h.`;
    return NextResponse.json(
      { ok: false, error, retryAfterSec: rl.retryAfterSec },
      { status: 429 },
    );
  }

  // M-3 (audit 2026-05-31): atomically reserve the in-flight slots BEFORE
  // broadcasting. On Upstash this is a SET-NX so two concurrent POSTs (even on
  // different Vercel instances) for the same address/IP cannot both proceed —
  // closing the cross-instance TOCTOU window the old per-instance Sets left
  // open. Reservation keys auto-expire so a crashed request can't lock a slot.
  const reservation = await reserveInflight(cooldownStore, recipient, ip);
  if (!reservation.ok) {
    return NextResponse.json(
      { ok: false, error: "A claim for this address or network is already in progress. Try again shortly." },
      { status: 429 },
    );
  }

  const txHashes: Record<string, `0x${string}`> = {};
  try {
    // M-3: consume one unit of the global hourly mint budget — a blunt
    // circuit-breaker bounding total faucet output per hour regardless of how
    // many distinct addresses/IPs ask. Refunded below if zero tokens broadcast.
    const budget = await consumeHourlyBudget(cooldownStore);
    if (!budget.ok) {
      await refundHourlyBudget(cooldownStore);
      return NextResponse.json(
        { ok: false, error: "Faucet is busy right now (hourly limit reached). Try again later." },
        { status: 429 },
      );
    }

    // M-2 (audit 2026-05-31): record the claim BEFORE broadcasting. Previously
    // recordClaim ran only on the success path, so a mid-batch failure (e.g.
    // token #4 reverts) returned 502 WITHOUT recording — letting the same
    // recipient/IP immediately re-POST and re-mint the tokens that DID land,
    // unbounded. We now record up-front and roll the claim back only if ZERO
    // tokens were broadcast, so a partial failure still consumes the cooldown.
    await recordClaim(cooldownStore, recipient, ip);

    // Build clients
    const account = privateKeyToAccount(key as `0x${string}`);
    const transport = http(
      process.env.NEXT_PUBLIC_RPC_URL || baseSepolia.rpcUrls.default.http[0],
    );
    const publicClient = createPublicClient({ chain: baseSepolia, transport });
    const walletClient = createWalletClient({ chain: baseSepolia, transport, account });

    try {
      // Pre-fetch the next nonce so back-to-back broadcasts don't collide
      // (viem's auto-nonce reads `pending` per-call and can repeat the same
      // value on serverless when txs haven't surfaced yet).
      let nonce = await publicClient.getTransactionCount({
        address: account.address,
        blockTag: "pending",
      });
      for (const t of FAUCET_TOKENS) {
        const value = t.amount * 10n ** BigInt(t.decimals);
        const hash = await walletClient.writeContract({
          chain: baseSepolia,
          account,
          address: t.address,
          abi: MINT_ABI,
          functionName: "mint",
          args: [recipient, value],
          nonce,
        });
        txHashes[t.symbol] = hash;
        nonce += 1;
      }
    } catch (e) {
      // I-12 (audit 2026-05-31): never leak raw viem/RPC detail to the client.
      // Log it server-side; return a generic message.
      console.error("[faucet] mint failed mid-flight:", e);

      // M-2: roll the claim back ONLY if nothing was broadcast. If even one
      // token landed, keep the cooldown — the re-mint window is what we're
      // closing. Net: one batch per cooldown window regardless of partial
      // failure. On total failure we also refund the hourly budget slot.
      if (Object.keys(txHashes).length === 0) {
        await rollbackClaim(cooldownStore, recipient, ip);
        await refundHourlyBudget(cooldownStore);
      }

      return NextResponse.json(
        { ok: false, error: "Faucet mint failed, please try again later." },
        { status: 502 },
      );
    }

    // Optionally wait for the LAST receipt so the client can show success
    // immediately. Keep this short-circuit so the response isn't held open
    // for the full 7-tx batch on slow networks.
    try {
      const lastSym = FAUCET_TOKENS[FAUCET_TOKENS.length - 1]!.symbol;
      const lastHash = txHashes[lastSym]!;
      await publicClient.waitForTransactionReceipt({ hash: lastHash, timeout: 8_000 });
    } catch {
      // Don't fail the response — txs were broadcast; client can poll the explorer.
    }

    return NextResponse.json({ ok: true, recipient, txHashes }, { status: 200 });
  } finally {
    // Always release the in-flight reservation so the next claim isn't blocked
    // for the full reservation TTL.
    await releaseInflight(cooldownStore, reservation.acquired);
  }
}
