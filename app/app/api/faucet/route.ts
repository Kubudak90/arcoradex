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

export const runtime = "nodejs";

// 7 stables + how much each claim mints. Decimals locked to live deploy.
// Amount choices: ~$1000 USD-equivalent each, rounded.
const TOKENS = [
  { symbol: "USDC",  address: "0x3BFa09fF6467639f0981948385bA1018Ac07d22C" as `0x${string}`, decimals: 6,  amount: 1_000n },
  { symbol: "USDT",  address: "0x342B6e4fD6896f0BCc80f8e9799e2bce65b9844B" as `0x${string}`, decimals: 6,  amount: 1_000n },
  { symbol: "PYUSD", address: "0xfdB2c86d010698401f0b969348DC58b6659B96a3" as `0x${string}`, decimals: 6,  amount: 1_000n },
  { symbol: "DAI",   address: "0xFf7d46fe2f672BB6dc1586613303c7b012aCafFE" as `0x${string}`, decimals: 18, amount: 1_000n },
  { symbol: "EURC",  address: "0xe08EF7Cb507706D8ff287A41Cf607Fb2d03473BD" as `0x${string}`, decimals: 6,  amount: 925n }, // ≈ $1000 at 1.08
  { symbol: "TRYC",  address: "0xD564EBcCFAE91f2E234b3074B0ad75eF7A820e61" as `0x${string}`, decimals: 6,  amount: 34_500n }, // ≈ $1000 at 0.029
  { symbol: "BRLC",  address: "0xa13c0935A98e2c175b31A4054f698819271a8FfC" as `0x${string}`, decimals: 6,  amount: 5_000n }, // ≈ $1000 at 0.20
];

const MINT_ABI = parseAbi(["function mint(address to, uint256 amount)"]);

// Per-address rate limit (in-memory, resets on cold start — fine for testnet).
const COOLDOWN_MS = 24 * 60 * 60 * 1000;
const lastClaim = new Map<string, number>();

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

  // Rate limit
  const now = Date.now();
  const last = lastClaim.get(recipient.toLowerCase());
  if (last && now - last < COOLDOWN_MS) {
    const retryAfterSec = Math.ceil((COOLDOWN_MS - (now - last)) / 1000);
    return NextResponse.json(
      {
        ok: false,
        error: `You already claimed in the last 24 hours. Try again in ${Math.ceil(retryAfterSec / 3600)}h.`,
        retryAfterSec,
      },
      { status: 429 },
    );
  }

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
    for (const t of TOKENS) {
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
    const lastSym = TOKENS[TOKENS.length - 1].symbol;
    const lastHash = txHashes[lastSym]!;
    await publicClient.waitForTransactionReceipt({ hash: lastHash, timeout: 8_000 });
  } catch {
    // Don't fail the response — txs were broadcast; client can poll the explorer.
  }

  lastClaim.set(recipient.toLowerCase(), now);

  return NextResponse.json({ ok: true, recipient, txHashes }, { status: 200 });
}
