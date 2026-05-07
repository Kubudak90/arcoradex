import * as React from "react";
import { cn } from "@/lib/utils";

export const Card = React.forwardRef<HTMLDivElement, React.HTMLAttributes<HTMLDivElement>>(
  ({ className, ...props }, ref) => (
    <div
      ref={ref}
      className={cn(
        "bg-surface border border-arc-ink-100 rounded-[20px] p-6",
        className,
      )}
      {...props}
    />
  ),
);
Card.displayName = "Card";

export const CardRaised = React.forwardRef<HTMLDivElement, React.HTMLAttributes<HTMLDivElement>>(
  ({ className, style, ...props }, ref) => (
    <div
      ref={ref}
      className={cn("bg-surface rounded-[20px] p-6", className)}
      style={{ boxShadow: "var(--shadow-md)", border: "1px solid transparent", ...style }}
      {...props}
    />
  ),
);
CardRaised.displayName = "CardRaised";

export const CardHeader = React.forwardRef<HTMLDivElement, React.HTMLAttributes<HTMLDivElement>>(
  ({ className, ...props }, ref) => (
    <div ref={ref} className={cn("flex items-center justify-between mb-4", className)} {...props} />
  ),
);
CardHeader.displayName = "CardHeader";

export const CardTitle = React.forwardRef<
  HTMLHeadingElement,
  React.HTMLAttributes<HTMLHeadingElement>
>(({ className, ...props }, ref) => (
  <h3 ref={ref} className={cn("t-title-l text-arc-ink-900", className)} {...props} />
));
CardTitle.displayName = "CardTitle";
