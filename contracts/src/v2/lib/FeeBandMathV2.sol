// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title FeeBandMathV2
/// @notice The ONE marginal band-traversal shared by quote and execution (spec §7).
/// All USD values are 1e18-scaled. Conservative rounding: maxima round DOWN, per-band
/// fees round UP, protocol fees round DOWN, the gross-from-debit inversion rounds DOWN
/// so execution never returns more than the matching quote.
library FeeBandMathV2 {
    uint256 internal constant BPS = 10_000;

    /// @param upperHealthBps Inclusive upper health bound of the band (descending order).
    /// @param rateBps Marginal fee rate charged on gross entitlement inside the band.
    struct Band {
        uint16 upperHealthBps;
        uint16 rateBps;
    }

    struct Result {
        bool ok;
        uint256 totalUserOutputUsd;
        uint256 totalProtocolFeeUsd;
        uint256 totalReserveDebitUsd;
        uint256 totalFeeUsd;
    }

    /// @dev Loop-invariant context for the band traversal. Bundled into one memory struct
    /// (passed by reference) solely to bound live stack slots in `_run`/`_consumeBand` and
    /// avoid stack-too-deep without via-IR; carries no economics of its own.
    /// @param available targetUsd - minUsd.
    /// @param excess Reserve above target (reserveUsd - targetUsd, else 0): per §7 this sits
    /// "in the healthiest band", so it is credited as extra debit capacity to BAND 0 only.
    /// @param protocolShareBps Protocol fee share.
    /// @param bands The descending fee schedule.
    struct Ctx {
        uint256 available;
        uint256 excess;
        uint256 protocolShareBps;
        Band[] bands;
    }

    /// @notice clamp(usableRemaining / available, 0, 1) expressed in bps. (§7)
    function healthBps(uint256 reserveUsd, uint256 minUsd, uint256 targetUsd) internal pure returns (uint256) {
        uint256 available = targetUsd - minUsd; // > 0 by §6.2
        uint256 usable = reserveUsd > minUsd ? reserveUsd - minUsd : 0;
        uint256 h = (usable * BPS) / available; // round down
        return h > BPS ? BPS : h;
    }

    /// @dev segmentReserveDebit as a function of gross, with §7 rounding.
    function _debitOf(uint256 gross, uint256 rateBps, uint256 protocolShareBps)
        private
        pure
        returns (uint256 userOut, uint256 protFee, uint256 fee, uint256 debit)
    {
        // fee rounds UP (Math.ceilDiv inlined): protects the floor.
        fee = (gross * rateBps + (BPS - 1)) / BPS;
        userOut = gross - fee;
        protFee = (fee * protocolShareBps) / BPS; // round down
        debit = userOut + protFee;
    }

    /// @dev Max gross whose reserveDebit fits `cap`, rounded DOWN, then trimmed so the
    /// forward-computed debit never exceeds `cap` (≤2 trims; ceil on fee can nudge it).
    function _grossForDebit(uint256 cap, uint256 rateBps, uint256 protocolShareBps)
        private
        pure
        returns (uint256 gross)
    {
        if (cap == 0) return 0;
        // debit ≈ gross * (BPS - rateBps + rateBps*protocolShareBps/BPS) / BPS
        // denom in BPS^2 units = (BPS - rateBps)*BPS + rateBps*protocolShareBps
        uint256 denom = (BPS - rateBps) * BPS + rateBps * protocolShareBps;
        gross = (cap * BPS * BPS) / denom; // round down
        // Forward-verify and trim (bounded): never let debit exceed cap.
        while (gross > 0) {
            (,,, uint256 d) = _debitOf(gross, rateBps, protocolShareBps);
            if (d <= cap) break;
            unchecked {
                --gross;
            }
        }
    }

    /// @dev Consume one band: given its precomputed debit capacity, find the gross that fits
    /// it (capped by remaining), accrue the segment's user-output/protocol-fee/fee into `res`,
    /// and return the gross consumed (`take`). Extracted from `traverse` solely to bound
    /// local-variable count (avoids stack-too-deep without via-IR); the arithmetic is
    /// identical to the inline §7 formulas. `res` is mutated in place (memory by reference).
    /// @param res Running totals to accrue into.
    /// @param ctx Loop-invariant context (carries `protocolShareBps`).
    /// @param bandDebitCap Reserve-debit capacity (USD) available in this band.
    /// @param rate Marginal fee rate for this band.
    /// @param remainingGross Gross still to be placed.
    /// @return take Gross consumed inside this band (0 if none consumable).
    function _consumeBand(Result memory res, Ctx memory ctx, uint256 bandDebitCap, uint256 rate, uint256 remainingGross)
        private
        pure
        returns (uint256 take)
    {
        if (bandDebitCap == 0) return 0;
        // Max gross that fits this band's debit capacity (rounded down), capped by remaining.
        take = _grossForDebit(bandDebitCap, rate, ctx.protocolShareBps);
        if (take > remainingGross) take = remainingGross;
        if (take == 0) return 0;
        (uint256 userOut, uint256 protFee, uint256 fee,) = _debitOf(take, rate, ctx.protocolShareBps);
        res.totalUserOutputUsd += userOut;
        res.totalProtocolFeeUsd += protFee;
        res.totalFeeUsd += fee;
    }

    /// @notice Consume `grossUsd` from the output reserve, descending through fee bands.
    /// Returns ok=false when the floor would be breached (caller must revert).
    /// @dev Thin wrapper: computes `available` and the clamped starting health, then
    /// delegates the band loop to `_run`. Split solely to bound live parameter/local count
    /// (avoids stack-too-deep without via-IR); economics are unchanged.
    function traverse(
        uint256 grossUsd,
        uint256 reserveUsd,
        uint256 minUsd,
        uint256 targetUsd,
        Band[] memory bands,
        uint256 protocolShareBps
    ) internal pure returns (Result memory res) {
        uint256 available = targetUsd - minUsd; // > 0 by §6.2
        uint256 usable = reserveUsd > minUsd ? reserveUsd - minUsd : 0;
        uint256 curHealthBps = (usable * BPS) / available;
        if (curHealthBps > BPS) curHealthBps = BPS;
        // §7: "Reserve above targetReserveUsd is in the healthiest band." The clamped health
        // caps band traversal at 100%, so the above-target excess would otherwise be dropped —
        // making a single large tx spill into deeper (pricier) bands while sequential split txs
        // each re-clamp at 100% and refill band 0, undercharging. Threading the excess into
        // band 0's debit capacity (see `_run`) restores the §14 anti-split guarantee: at or
        // below target excess is 0, so that regime stays byte-identical.
        uint256 excess = reserveUsd > targetUsd ? reserveUsd - targetUsd : 0;
        return _run(
            Ctx({available: available, excess: excess, protocolShareBps: protocolShareBps, bands: bands}),
            grossUsd,
            curHealthBps
        );
    }

    /// @dev The band loop. `ctx.available = targetUsd - minUsd`, `curHealthBps` already
    /// clamped to [0, BPS]. Returns ok=false when the floor would be breached.
    function _run(Ctx memory ctx, uint256 remainingGross, uint256 curHealthBps)
        private
        pure
        returns (Result memory res)
    {
        uint256 n = ctx.bands.length;
        for (uint256 i; i < n && remainingGross > 0; ++i) {
            Band memory band = ctx.bands[i];
            uint256 lower = (i + 1 < n) ? ctx.bands[i + 1].upperHealthBps : 0;
            // Top of the consumable region in this band is the lower of the band's
            // upper bound and the current health.
            uint256 topBps = band.upperHealthBps < curHealthBps ? band.upperHealthBps : curHealthBps;
            if (topBps <= lower) continue; // band entirely above current health

            // Debit capacity in USD between topBps and lower (both round down). For BAND 0
            // (i == 0) add the above-target excess: §7 places it "in the healthiest band", so
            // it is healthiest-band debit capacity, not band-1+ capacity. This is the whole
            // fix — every other band is unchanged, and at/below target ctx.excess == 0 so the
            // capacity (and thus all downstream economics) is byte-identical to before.
            uint256 cap = (ctx.available * topBps) / BPS - (ctx.available * lower) / BPS;
            if (i == 0) cap += ctx.excess;
            // gross that fits it (capped by remaining); _consumeBand accrues into `res`.
            uint256 take = _consumeBand(res, ctx, cap, band.rateBps, remainingGross);
            if (take == 0) {
                // Band has capacity in USD but not enough to admit 1 wei of gross net
                // of the rounded-up fee; nothing consumable here — move on.
                continue;
            }
            remainingGross -= take;
            // Drop current health to this band's lower bound only if we filled it;
            // a partial fill ends the loop (remainingGross hits 0).
            curHealthBps = lower;
        }
        if (remainingGross != 0) {
            // Could not place all gross above the floor.
            res.ok = false;
            return res;
        }
        res.ok = true;
        res.totalReserveDebitUsd = res.totalUserOutputUsd + res.totalProtocolFeeUsd;
    }
}
