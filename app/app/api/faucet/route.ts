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
import { arcTestnet } from "@arcoralabs/dex-sdk";
import { checkBotId } from "botid/server";
import {
  MemoryCooldownStore,
  checkRateLimit,
  recordClaim,
  extractClientIp,
} from "@/lib/faucet-rate-limit";
import { FAUCET_TOKENS } from "@/lib/faucet-tokens";

export const runtime = "nodejs";

const MINT_ABI = parseAbi(["function mint(address to, uint256 amount)"]);

// Cooldown is keyed by both recipient address AND client IP — fresh-wallet
// spam from a single client gets caught by the per-IP key. In-memory store is
// per-instance and resets on cold start; acceptable for testnet (Vercel BotID
// is the real defense vs. botnets, the cooldown is best-effort UX bound).
const cooldownStore = new MemoryCooldownStore();

// H-6 (audit 2026-05-24): close the per-instance TOCTOU window between
// checkRateLimit and recordClaim. Two near-simultaneous POSTs for the same
// recipient or IP would both pass the rate-limit read before either's write
// landed, ending up with two 7-tx mint batches. Module-scoped Sets serve as
// an in-process mutex; cross-instance races are still possible but require
// the same recipient to land on two different Vercel function invocations
// within the same ~10 s window (uncommon on Fluid Compute warm-paths).
const inFlightAddrs = new Set<string>();
const inFlightIps = new Set<string>();

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
  // In dev (NEXT_PUBLIC_APP_URL unset) the check is skipped.
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

  // Rate limit: per-recipient AND per-IP (best-effort, in-memory).
  const ip = extractClientIp(req);
  const rl = checkRateLimit(cooldownStore, recipient, ip);
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

  // H-6 (audit 2026-05-24): atomically reserve the rate-limit slots BEFORE
  // broadcasting. Without this, two concurrent POSTs both pass checkRateLimit
  // and both run the mint loop. Reservation is per-instance only — see the
  // module-level comment for the cross-instance caveat.
  const addrKey = recipient.toLowerCase();
  if (inFlightAddrs.has(addrKey) || (ip != null && inFlightIps.has(ip))) {
    return NextResponse.json(
      { ok: false, error: "A claim for this address or network is already in progress. Try again shortly." },
      { status: 429 },
    );
  }
  inFlightAddrs.add(addrKey);
  if (ip != null) inFlightIps.add(ip);

  try {
    // Build clients
    const account = privateKeyToAccount(key as `0x${string}`);
    const transport = http(process.env.NEXT_PUBLIC_RPC_URL || "https://rpc.testnet.arc.network");
    const publicClient = createPublicClient({ chain: arcTestnet, transport });
    const walletClient = createWalletClient({ chain: arcTestnet, transport, account });

    const txHashes: Record<string, `0x${string}`> = {};
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
          chain: arcTestnet,
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
      return NextResponse.json(
        {
          ok: false,
          error: `Mint failed mid-flight: ${(e as Error).message}. Some tokens may have arrived.`,
        },
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

    // Record the claim only after a successful broadcast so a mid-flight revert
    // doesn't lock out the user (txs are atomic per-token but the mint loop can
    // partially fail; in that case the catch above already returned 502).
    recordClaim(cooldownStore, recipient, ip);

    return NextResponse.json({ ok: true, recipient, txHashes }, { status: 200 });
  } finally {
    inFlightAddrs.delete(addrKey);
    if (ip != null) inFlightIps.delete(ip);
  }
}
