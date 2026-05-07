"use client";
import { useAccount } from "wagmi";
import { usePosition, usePoolStats } from "@arcoralabs/dex-sdk/react";
import { fmtUnits, fmtUSD } from "@arcoralabs/dex-sdk";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";

export function PositionPanel() {
  const { address: account } = useAccount();
  const { position, isLoading } = usePosition();
  const { stats } = usePoolStats({ refetchOnBlock: true });

  if (!account) return null;
  if (isLoading || !position || !stats) {
    return (
      <Card>
        <p className="text-sm text-arc-ink-500">Loading position…</p>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Your position</CardTitle>
      </CardHeader>
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-6 text-sm">
        <div>
          <p className="t-label m-0 mb-1">Your ADEX-LP</p>
          <p className="t-mono text-2xl font-medium text-arc-ink-900">
            {fmtUnits(position.lpBalance, 18, 4)}
          </p>
        </div>
        <div>
          <p className="t-label m-0 mb-1">Position value</p>
          <p className="t-mono text-2xl font-medium text-arc-ink-900">
            {fmtUSD(position.usdValue1e18)}
          </p>
        </div>
        <div>
          <p className="t-label m-0 mb-1">1 ADEX-LP</p>
          <p className="t-mono text-2xl font-medium text-arc-ink-900">
            {fmtUSD(stats.lpPriceUsd1e18)}
          </p>
        </div>
      </div>
    </Card>
  );
}
