import { ReservesTable } from "@/components/pool/ReservesTable";
import { RecentSwapsCard } from "@/components/pool/RecentSwapsCard";

export default function PoolPage() {
  return (
    <div className="grid grid-cols-1 lg:grid-cols-[1fr_460px] gap-8 items-start">
      <ReservesTable />
      <RecentSwapsCard />
    </div>
  );
}
