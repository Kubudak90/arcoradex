"use client";
import { useState } from "react";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { DepositTab } from "@/components/liquidity/DepositTab";
import { WithdrawTab } from "@/components/liquidity/WithdrawTab";
import { PositionPanel } from "@/components/liquidity/PositionPanel";

export default function LiquidityPage() {
  const [tab, setTab] = useState("deposit");
  return (
    <div className="grid grid-cols-1 lg:grid-cols-[420px_1fr] gap-8 items-start">
      <div
        className="bg-surface rounded-[28px] p-5"
        style={{ boxShadow: "var(--shadow-md)", border: "1px solid var(--arc-ink-100)" }}
      >
        <div className="flex items-center justify-between mb-3.5">
          <div className="t-title-l">Liquidity</div>
        </div>
        <Tabs value={tab} onValueChange={setTab}>
          <TabsList className="w-full mb-3">
            <TabsTrigger value="deposit" className="flex-1">
              Deposit
            </TabsTrigger>
            <TabsTrigger value="withdraw" className="flex-1">
              Withdraw
            </TabsTrigger>
          </TabsList>
          <TabsContent value="deposit">
            <DepositTab />
          </TabsContent>
          <TabsContent value="withdraw">
            <WithdrawTab />
          </TabsContent>
        </Tabs>
      </div>

      <div className="flex flex-col gap-5">
        <PositionPanel />
      </div>
    </div>
  );
}
