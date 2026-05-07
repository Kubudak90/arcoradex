"use client";

export function CircleFaucetLink() {
  return (
    <a
      href="https://faucet.circle.com/"
      target="_blank"
      rel="noreferrer"
      className="hidden sm:inline-flex items-center gap-1.5 h-9 px-3.5 rounded-full text-[13px] font-medium bg-arc-ink-50 text-arc-ink-900 hover:bg-arc-ink-100 transition-colors"
      title="Claim USDC on Arc Testnet for gas (Circle faucet)"
    >
      <span className="ms" style={{ fontSize: 16 }}>
        local_gas_station
      </span>
      Gas USDC
      <span className="ms" style={{ fontSize: 13, opacity: 0.55 }}>
        open_in_new
      </span>
    </a>
  );
}
