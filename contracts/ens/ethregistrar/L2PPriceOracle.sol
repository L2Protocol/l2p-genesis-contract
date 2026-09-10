//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import "./IPriceOracle.sol";
import "../utils/StringUtils.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Prices names directly in L2P, for a chain without a price feed.
///
/// @dev This is upstream's StablePriceOracle plus ExponentialPremiumPriceOracle with the USD
///      indirection removed: rent prices are fixed amounts of wei per year rather than attoUSD per
///      second, so no aggregator is consulted. The premium decay is upstream's, unchanged.
contract L2PPriceOracle is IPriceOracle {
    using StringUtils for *;

    uint256 constant GRACE_PERIOD = 90 days;
    uint256 constant SECONDS_PER_YEAR = 365 days;

    /// @notice Rent in wei per year, by label length.
    uint256 public immutable price1Letter;
    uint256 public immutable price2Letter;
    uint256 public immutable price3Letter;
    uint256 public immutable price4Letter;
    uint256 public immutable price5Letter;

    /// @notice The premium a name carries the moment its grace period ends, in wei.
    uint256 public immutable startPremium;

    /// @notice The premium remaining after the decay period, subtracted so the curve ends at zero.
    uint256 public immutable endValue;

    /// @param _rentPrices Yearly rent in wei for labels of 1, 2, 3, 4 and 5-or-more characters.
    /// @param _startPremium The premium in wei at the moment a name's grace period ends.
    /// @param totalDays The number of days over which that premium halves down to zero.
    constructor(
        uint256[] memory _rentPrices,
        uint256 _startPremium,
        uint256 totalDays
    ) {
        price1Letter = _rentPrices[0];
        price2Letter = _rentPrices[1];
        price3Letter = _rentPrices[2];
        price4Letter = _rentPrices[3];
        price5Letter = _rentPrices[4];
        startPremium = _startPremium;
        endValue = _startPremium >> totalDays;
    }

    /// @inheritdoc IPriceOracle
    function price(
        string calldata name,
        uint256 expires,
        uint256 duration
    ) external view override returns (IPriceOracle.Price memory) {
        uint256 len = name.strlen();
        uint256 basePrice;

        if (len >= 5) {
            basePrice = price5Letter * duration;
        } else if (len == 4) {
            basePrice = price4Letter * duration;
        } else if (len == 3) {
            basePrice = price3Letter * duration;
        } else if (len == 2) {
            basePrice = price2Letter * duration;
        } else {
            basePrice = price1Letter * duration;
        }
        basePrice /= SECONDS_PER_YEAR;

        return IPriceOracle.Price({ base: basePrice, premium: _premium(expires) });
    }

    /// @notice Returns the pricing premium in wei.
    function premium(
        string calldata,
        uint256 expires,
        uint256
    ) external view returns (uint256) {
        return _premium(expires);
    }

    function _premium(
        uint256 expires
    ) internal view returns (uint256) {
        expires = expires + GRACE_PERIOD;
        if (expires > block.timestamp) {
            return 0;
        }

        uint256 elapsed = block.timestamp - expires;
        uint256 decayed = decayedPremium(startPremium, elapsed);
        if (decayed >= endValue) {
            return decayed - endValue;
        }
        return 0;
    }

    uint256 constant PRECISION = 1e18;
    uint256 constant bit1 = 999989423469314432; // 0.5 ^ 1/65536 * (10 ** 18)
    uint256 constant bit2 = 999978847050491904; // 0.5 ^ 2/65536 * (10 ** 18)
    uint256 constant bit3 = 999957694548431104;
    uint256 constant bit4 = 999915390886613504;
    uint256 constant bit5 = 999830788931929088;
    uint256 constant bit6 = 999661606496243712;
    uint256 constant bit7 = 999323327502650752;
    uint256 constant bit8 = 998647112890970240;
    uint256 constant bit9 = 997296056085470080;
    uint256 constant bit10 = 994599423483633152;
    uint256 constant bit11 = 989228013193975424;
    uint256 constant bit12 = 978572062087700096;
    uint256 constant bit13 = 957603280698573696;
    uint256 constant bit14 = 917004043204671232;
    uint256 constant bit15 = 840896415253714560;
    uint256 constant bit16 = 707106781186547584;

    /// @dev Returns the premium price at current time elapsed
    /// @param _startPremium starting price
    /// @param elapsed time past since expiry
    function decayedPremium(
        uint256 _startPremium,
        uint256 elapsed
    ) public pure returns (uint256) {
        uint256 daysPast = (elapsed * PRECISION) / 1 days;
        uint256 intDays = daysPast / PRECISION;
        uint256 _premiumValue = _startPremium >> intDays;
        uint256 partDay = (daysPast - intDays * PRECISION);
        uint256 fraction = (partDay * (2 ** 16)) / PRECISION;
        return addFractionalPremium(fraction, _premiumValue);
    }

    function addFractionalPremium(
        uint256 fraction,
        uint256 _premiumValue
    ) internal pure returns (uint256) {
        if (fraction & (1 << 0) != 0) {
            _premiumValue = (_premiumValue * bit1) / PRECISION;
        }
        if (fraction & (1 << 1) != 0) {
            _premiumValue = (_premiumValue * bit2) / PRECISION;
        }
        if (fraction & (1 << 2) != 0) {
            _premiumValue = (_premiumValue * bit3) / PRECISION;
        }
        if (fraction & (1 << 3) != 0) {
            _premiumValue = (_premiumValue * bit4) / PRECISION;
        }
        if (fraction & (1 << 4) != 0) {
            _premiumValue = (_premiumValue * bit5) / PRECISION;
        }
        if (fraction & (1 << 5) != 0) {
            _premiumValue = (_premiumValue * bit6) / PRECISION;
        }
        if (fraction & (1 << 6) != 0) {
            _premiumValue = (_premiumValue * bit7) / PRECISION;
        }
        if (fraction & (1 << 7) != 0) {
            _premiumValue = (_premiumValue * bit8) / PRECISION;
        }
        if (fraction & (1 << 8) != 0) {
            _premiumValue = (_premiumValue * bit9) / PRECISION;
        }
        if (fraction & (1 << 9) != 0) {
            _premiumValue = (_premiumValue * bit10) / PRECISION;
        }
        if (fraction & (1 << 10) != 0) {
            _premiumValue = (_premiumValue * bit11) / PRECISION;
        }
        if (fraction & (1 << 11) != 0) {
            _premiumValue = (_premiumValue * bit12) / PRECISION;
        }
        if (fraction & (1 << 12) != 0) {
            _premiumValue = (_premiumValue * bit13) / PRECISION;
        }
        if (fraction & (1 << 13) != 0) {
            _premiumValue = (_premiumValue * bit14) / PRECISION;
        }
        if (fraction & (1 << 14) != 0) {
            _premiumValue = (_premiumValue * bit15) / PRECISION;
        }
        if (fraction & (1 << 15) != 0) {
            _premiumValue = (_premiumValue * bit16) / PRECISION;
        }
        return _premiumValue;
    }

    function supportsInterface(
        bytes4 interfaceID
    ) public view virtual returns (bool) {
        return interfaceID == type(IERC165).interfaceId || interfaceID == type(IPriceOracle).interfaceId;
    }
}
