import { SwapCard } from "@/components/swap/SwapCard";

export default function SwapPage() {
  return (
    <div className="space-y-8">
      <div className="text-center max-w-2xl mx-auto">
        <h1 className="text-4xl font-bold tracking-tight">
          Swap stablecoins on{" "}
          <span className="text-wordmark">ArcoraDEX</span>
        </h1>
        <p className="mt-3 text-fg-muted">
          Oracle-priced, public-LP, multi-stable shared vault on Arc.
        </p>
      </div>
      <SwapCard />
    </div>
  );
}
