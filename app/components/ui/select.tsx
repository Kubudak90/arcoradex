"use client";
import { cn } from "@/lib/utils";

interface SelectProps {
  value: string;
  onChange: (v: string) => void;
  options: { value: string; label: string }[];
  className?: string;
}

export function Select({ value, onChange, options, className }: SelectProps) {
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className={cn(
        "h-11 rounded-full border border-arc-ink-200 bg-surface px-4 text-sm text-arc-ink-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-arc-blue-200 focus-visible:border-arc-blue-400 transition-shadow",
        className,
      )}
    >
      {options.map((o) => (
        <option key={o.value} value={o.value}>
          {o.label}
        </option>
      ))}
    </select>
  );
}
