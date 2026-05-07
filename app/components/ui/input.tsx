import * as React from "react";
import { cn } from "@/lib/utils";

export const Input = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement>>(
  ({ className, ...props }, ref) => (
    <input
      ref={ref}
      className={cn(
        "flex h-11 w-full rounded-full border border-arc-ink-200 bg-surface px-4 text-sm text-arc-ink-900 placeholder:text-arc-ink-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-arc-blue-200 focus-visible:border-arc-blue-400 disabled:opacity-50 disabled:cursor-not-allowed transition-shadow",
        className,
      )}
      {...props}
    />
  ),
);
Input.displayName = "Input";
