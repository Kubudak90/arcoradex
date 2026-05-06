"use client";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { DepositTab } from "@/components/liquidity/DepositTab";
import { WithdrawTab } from "@/components/liquidity/WithdrawTab";
import { PositionPanel } from "@/components/liquidity/PositionPanel";

export default function LiquidityPage() {
  return (
    <div className="space-y-8 max-w-md mx-auto">
      <PositionPanel />
      <Card>
        <CardHeader>
          <CardTitle>Liquidity</CardTitle>
        </CardHeader>
        <Tabs defaultValue="deposit">
          <TabsList className="w-full">
            <TabsTrigger value="deposit" className="flex-1">Deposit</TabsTrigger>
            <TabsTrigger value="withdraw" className="flex-1">Withdraw</TabsTrigger>
          </TabsList>
          <TabsContent value="deposit"><DepositTab /></TabsContent>
          <TabsContent value="withdraw"><WithdrawTab /></TabsContent>
        </Tabs>
      </Card>
    </div>
  );
}
