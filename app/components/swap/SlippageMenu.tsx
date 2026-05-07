"use client";
import { useState } from "react";
import { Modal } from "@/components/ui/modal";

interface Props {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  slippageBps: number;
  onSlippageChange: (bps: number) => void;
  deadlineMin: number;
  onDeadlineChange: (m: number) => void;
}

const PRESETS = [10, 50, 100]; // 0.1%, 0.5%, 1%

export function SlippageMenu({
  open,
  onOpenChange,
  slippageBps,
  onSlippageChange,
  deadlineMin,
  onDeadlineChange,
}: Props) {
  const [custom, setCustom] = useState(
    PRESETS.includes(slippageBps) ? "" : (slippageBps / 100).toString(),
  );

  function applyCustom(value: string) {
    setCustom(value);
    const n = parseFloat(value);
    if (!isNaN(n) && n >= 0 && n <= 50) onSlippageChange(Math.round(n * 100));
  }

  return (
    <Modal open={open} onOpenChange={onOpenChange} title="Transaction settings">
      <div className="space-y-5 mt-2">
        <div>
          <div className="t-title-s text-arc-ink-700 mb-2">Slippage tolerance</div>
          <div className="flex gap-2 flex-wrap">
            {PRESETS.map((bps) => (
              <button
                key={bps}
                onClick={() => {
                  onSlippageChange(bps);
                  setCustom("");
                }}
                className="h-10 px-4 rounded-full text-sm font-medium transition-colors"
                style={{
                  background: slippageBps === bps ? "var(--arc-ink-900)" : "var(--arc-ink-50)",
                  color: slippageBps === bps ? "white" : "var(--arc-ink-700)",
                }}
              >
                {bps / 100}%
              </button>
            ))}
            <div
              className="flex items-center gap-1 px-3 h-10 rounded-full bg-arc-ink-50 focus-within:ring-2 focus-within:ring-arc-blue-200 focus-within:bg-surface"
              style={{ minWidth: 110 }}
            >
              <input
                type="text"
                inputMode="decimal"
                placeholder="Custom"
                value={custom}
                onChange={(e) => applyCustom(e.target.value)}
                className="bg-transparent border-0 outline-none text-sm w-16 text-right t-mono"
              />
              <span className="text-arc-ink-500 text-sm">%</span>
            </div>
          </div>
          {slippageBps >= 500 ? (
            <p className="mt-2 text-xs" style={{ color: "var(--color-warn)" }}>
              ⚠ High slippage. Your trade may be front-run.
            </p>
          ) : null}
        </div>

        <div>
          <div className="t-title-s text-arc-ink-700 mb-2">Transaction deadline</div>
          <div
            className="inline-flex items-center gap-1 px-3 h-10 rounded-full bg-arc-ink-50 focus-within:ring-2 focus-within:ring-arc-blue-200 focus-within:bg-surface"
            style={{ minWidth: 140 }}
          >
            <input
              type="number"
              min={1}
              max={120}
              value={deadlineMin}
              onChange={(e) => {
                const n = parseInt(e.target.value, 10);
                if (!isNaN(n) && n >= 1 && n <= 120) onDeadlineChange(n);
              }}
              className="bg-transparent border-0 outline-none text-sm w-12 text-right t-mono"
            />
            <span className="text-arc-ink-500 text-sm">minutes</span>
          </div>
        </div>
      </div>
    </Modal>
  );
}
