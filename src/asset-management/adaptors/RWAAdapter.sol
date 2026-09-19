// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseAdapter} from "./BaseAdapter.sol";
import {INAVOracle} from "../../interfaces/INAVOracle.sol";

/// @title RWAAdapter
/// @notice BaseAdapter that values its RWA Token balance via a token-keyed NAVOracle price feed.
///         Never stores or reads an assetId, never calls AssetRegistry — the RWA Token may be
///         HyperTessera's own or issued by an external party.
contract RWAAdapter is BaseAdapter {
    using SafeERC20 for IERC20;

    address public immutable rwaToken;
    address public immutable navOracle;

    error NAVUnavailable(address rwaToken);

    constructor(IERC20 asset_, address vault_, address rwaToken_, address navOracle_, uint256 dealDataStalenessWindow_)
        BaseAdapter(asset_, vault_, dealDataStalenessWindow_, "RWA Adapter Share", "rwaShare")
    {
        if (rwaToken_ == address(0) || navOracle_ == address(0)) revert ZeroAddress();
        rwaToken = rwaToken_;
        navOracle = navOracle_;
    }

    // -----------------------------------------------------------------------
    // Exit-asset policy — this Adapter sells its own RWA Token and nothing else
    // -----------------------------------------------------------------------

    /// @dev The standalone RWA Withdraw order book was removed and RWA sales run
    ///      through the generic Sell Order instead. It could transfer RWA out with no payment at
    ///      all, which sidestepped the pay-first rule the Sell Order exists to enforce; it left
    ///      two books competing for the same token balance, so the reservation accounting had to
    ///      span both; and a withdrawal with no proceeds dropped the balance with no matching
    ///      cash and no Deal treatment. Everything it did, the Sell Order does with the payment
    ///      and the position retirement attached. A no-proceeds emergency migration, if it is ever
    ///      needed, belongs in a purpose-built Governance mechanism, not in the ordinary
    ///      business flow.
    ///
    ///      Narrowing to `rwaToken` is what keeps a Sell Order from being used to move any other
    ///      token this Adapter happens to hold.
    function _validateExitAsset(address token, uint256 amount) internal view override {
        amount;
        if (token != rwaToken) revert ExitAssetNotSupported(token);
    }

    function _deliverExitAsset(address token, uint256 amount, address to) internal override {
        if (token != rwaToken) revert ExitAssetNotSupported(token);
        IERC20(rwaToken).safeTransfer(to, amount);
    }

    /// @dev Tokens already delivered into this Adapter are valued at `balance × price`. The
    ///      in-flight cost of the TOKEN_RETURN orders that delivered them is netted out, so an
    ///      order that has been filled but whose pending entry the Allocator has not yet cleared
    ///      via `clearDealValue` is never counted twice.
    ///      `clearDealValue` remains the way to retire the
    ///      entry for good; this only stops the gap between delivery and clearing from inflating
    ///      NAV. VALUE_RETURN deals are untouched — no balance ever supersedes them.
    function realAssets() public view override returns (uint256) {
        uint256 pending = super.realAssets();
        uint256 balance = IERC20(rwaToken).balanceOf(address(this));
        if (balance == 0) return pending;

        (uint256 price,) = INAVOracle(navOracle).getNAV(rwaToken);
        if (price == 0) revert NAVUnavailable(rwaToken);

        uint256 tokenValue = _tokenValue(balance, price);
        uint256 superseded = Math.min(_liveTokenReturnDealValue(), tokenValue);

        // `superseded <= _liveTokenReturnDealValue() <= pending`, so this cannot underflow.
        return pending - superseded + tokenValue;
    }

    /// @dev Converts `balance` (rwaToken's own decimals) at `price` (1e18-scale, per one whole
    ///      rwaToken) into the Vault's accounting-asset smallest units.
    function _tokenValue(uint256 balance, uint256 price) internal view returns (uint256) {
        uint8 rwaDecimals = IERC20Metadata(rwaToken).decimals();
        uint8 assetDecimals = IERC20Metadata(asset()).decimals();
        // mulDiv's 512-bit intermediate only protects its own internal a*b step, so `balance`
        // and `price` must reach mulDiv unmultiplied for that protection to cover their product;
        // pre-scaling `price` by 10**assetDecimals here is a plain multiplication, but price is an
        // admin-signed, 1e18-scale NAV value nowhere near the magnitude needed to overflow uint256.
        return Math.mulDiv(balance, price * 10 ** assetDecimals, 10 ** rwaDecimals * 1e18);
    }
}
