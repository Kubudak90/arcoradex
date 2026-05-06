"use client";
import type { TokenInfo as TokenRow } from "@arcoralabs/dex-sdk";
import { Select } from "@/components/ui/select";

interface Props {
  tokens: TokenRow[];
  value?: `0x${string}`;
  onChange: (v: `0x${string}`) => void;
  exclude?: `0x${string}`;
  className?: string;
}

export function TokenSelect({ tokens, value, onChange, exclude, className }: Props) {
  const opts = tokens
    .filter((t) => t.address !== exclude)
    .map((t) => ({ value: t.address, label: `${t.symbol} — ${t.name}` }));
  return (
    <Select
      value={value ?? opts[0]?.value ?? ""}
      onChange={(v) => onChange(v as `0x${string}`)}
      options={opts}
      className={className}
    />
  );
}
