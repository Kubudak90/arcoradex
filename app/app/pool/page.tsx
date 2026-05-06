import { ReservesTable } from "@/components/pool/ReservesTable";
import { SwapHistory } from "@/components/pool/SwapHistory";

export default function PoolPage() {
  return (
    <div className="space-y-8">
      <ReservesTable />
      <SwapHistory />
    </div>
  );
}
