import { SwapCard } from "@/components/swap/SwapCard";
import { RecentSwapsCard } from "@/components/pool/RecentSwapsCard";

export default function SwapPage() {
  return (
    <div className="grid grid-cols-1 lg:grid-cols-[420px_1fr] gap-8 items-start">
      <SwapCard />
      <div className="flex flex-col gap-5">
        <RecentSwapsCard />
      </div>
    </div>
  );
}
