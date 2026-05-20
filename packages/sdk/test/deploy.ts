import { spawn, type ChildProcess } from "node:child_process";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { getAddress } from "viem";

const __dirname = dirname(fileURLToPath(import.meta.url));

export interface DeployedTokenInfo {
  symbol: string;
  address: `0x${string}`;
  decimals: number;
  feed: `0x${string}`;
}

export interface DeployedAddresses {
  registry: `0x${string}`;
  pool: `0x${string}`;
  lp: `0x${string}`;
  tokens: DeployedTokenInfo[];
}

export interface AnvilHandle {
  rpcUrl: string;
  port: number;
  proc: ChildProcess;
  stop: () => void;
}

const ANVIL_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

/** Spawns a local Anvil process on a random port, with chainId 5042002.
 *
 * We start the chain 2 hours behind real wall-clock time so that:
 *   1. The initial LP deposits (in deployContracts) set lastMintAt to T-2h.
 *   2. The withdraw integration test can advance time by 3601 s to clear the
 *      1-hour MIN_HOLD_SECONDS window (chain time becomes T-2h+3601s ≈ T-1h)
 *      while still leaving chain time ~1 hour behind real Date.now(). This
 *      means the SDK's default deadline (Date.now()+20min) remains far in the
 *      future from the chain's perspective, so subsequent test transactions
 *      (deposit, swap, etc.) are not broken by the time warp.
 */
export async function spawnAnvil(): Promise<AnvilHandle> {
  const port = 8545 + Math.floor(Math.random() * 1000);
  // Start the genesis block 2 hours behind real time (see module-level comment).
  const genesisTimestamp = Math.floor(Date.now() / 1000) - 2 * 3600;
  const proc = spawn(
    "anvil",
    [
      "--silent",
      "--port", String(port),
      "--chain-id", "5042002",
      "--hardfork", "cancun",
      "--timestamp", String(genesisTimestamp),
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  // Wait briefly for Anvil to bind. Poll the RPC port until it's responsive.
  const rpcUrl = `http://127.0.0.1:${port}`;
  const deadline = Date.now() + 10_000;
  let ready = false;
  while (!ready) {
    try {
      const r = await fetch(rpcUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
      });
      if (r.ok) ready = true;
    } catch {
      /* not yet listening */
    }
    if (!ready && Date.now() > deadline) {
      proc.kill("SIGTERM");
      throw new Error(`anvil failed to start on port ${port} within 10s`);
    }
    if (!ready) await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return {
    rpcUrl,
    port,
    proc,
    stop: () => {
      proc.kill("SIGTERM");
    },
  };
}

interface BroadcastTx {
  contractName?: string;
  contractAddress?: string;
  transactionType?: string;
  additionalContracts?: Array<{
    transactionType?: string;
    contractName?: string;
    address?: string;
  }>;
}

interface BroadcastFile {
  transactions: BroadcastTx[];
}

/** Runs the existing DeployArcoraDex.s.sol against the given RPC. Returns the parsed addresses. */
export function deployContracts(rpcUrl: string): DeployedAddresses {
  // packages/sdk/test/deploy.ts -> packages/sdk/test -> packages/sdk -> packages -> repo root
  const repoRoot = join(__dirname, "..", "..", "..");
  const contractsDir = join(repoRoot, "contracts");

  execFileSync(
    "forge",
    [
      "script",
      "script/DeployArcoraDex.s.sol",
      "--rpc-url",
      rpcUrl,
      "--broadcast",
      "--silent",
      "--private-key",
      ANVIL_PRIVATE_KEY,
    ],
    {
      cwd: contractsDir,
      env: { ...process.env, PRIVATE_KEY: ANVIL_PRIVATE_KEY },
      stdio: "pipe",
    },
  );

  const broadcastFile = join(
    contractsDir,
    "broadcast",
    "DeployArcoraDex.s.sol",
    "5042002",
    "run-latest.json",
  );
  const data = JSON.parse(readFileSync(broadcastFile, "utf8")) as BroadcastFile;

  const out: DeployedAddresses = {
    registry: "0x0000000000000000000000000000000000000000",
    pool: "0x0000000000000000000000000000000000000000",
    lp: "0x0000000000000000000000000000000000000000",
    tokens: [],
  };

  // Deploy script order per token: MintableERC20 (CREATE), MockChainlinkFeed (CREATE),
  //   listToken (CALL), mint (CALL), approve (CALL), deposit (CALL).
  // ArcoraDexLP is created inside ArcoraDexPool's constructor and shows up as an
  //   `additionalContracts[0]` entry on the pool's CREATE tx, not as a top-level CREATE.
  const symbols = ["USDC", "USDT", "PYUSD", "DAI", "EURC", "TRYC", "BRLC"];
  const decimals = [6, 6, 6, 18, 6, 6, 6];
  let tokenIdx = 0;

  for (const tx of data.transactions) {
    if (tx.transactionType !== "CREATE") continue;
    const addr = tx.contractAddress;
    if (!addr || !tx.contractName) continue;
    if (tx.contractName === "ArcoraDexRegistry") {
      out.registry = getAddress(addr);
    } else if (tx.contractName === "ArcoraDexPool") {
      out.pool = getAddress(addr);
      // The LP comes back nested inside additionalContracts on the pool create.
      const lp = (tx.additionalContracts ?? []).find((c) => c.contractName === "ArcoraDexLP");
      if (lp?.address) out.lp = getAddress(lp.address);
    } else if (tx.contractName === "MintableERC20") {
      out.tokens.push({
        symbol: symbols[tokenIdx]!,
        address: getAddress(addr),
        decimals: decimals[tokenIdx]!,
        feed: "0x0000000000000000000000000000000000000000",
      });
    } else if (tx.contractName === "MockChainlinkFeed") {
      const last = out.tokens[out.tokens.length - 1];
      if (last) last.feed = getAddress(addr);
      tokenIdx++;
    }
  }
  return out;
}
