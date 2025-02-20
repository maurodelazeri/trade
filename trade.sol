// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.10;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IOracle} from "../lib/morpho-blue/src/interfaces/IOracle.sol";
import {MathLib, WAD} from "../lib/morpho-blue/src/libraries/MathLib.sol";
import {SharesMathLib} from "../lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "../lib/morpho-blue/src/libraries/ConstantsLib.sol";

interface IMorpho {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    struct Position {
        uint128 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
    function market(bytes32 id) external view returns (
        uint256 totalSupplyAssets,
        uint256 totalSupplyShares,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares,
        uint256 lastUpdate,
        uint256 fee
    );
    function position(bytes32 id, address user) external view returns (Position memory);
    function liquidate(MarketParams memory marketParams, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes memory data) external returns (uint256, uint256);
}

struct PreLiquidationParams {
    uint256 preLltv;
    uint256 preLCF1;
    uint256 preLCF2;
    uint256 preLIF1;
    uint256 preLIF2;
    address preLiquidationOracle;
}

interface IPreLiquidation {
    function preLiquidate(address borrower, uint256 seizedAssets, uint256 repaidShares, bytes calldata data) external returns (uint256, uint256);
    function preLiquidationParams() external view returns (PreLiquidationParams memory);
}

interface IPool {
    function flashLoanSimple(address receiverAddress, address asset, uint256 amount, bytes calldata params, uint16 referralCode) external;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MorphoTrader {
    using MathLib for uint256;
    using SharesMathLib for uint256;

    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    address public immutable PRELIQUIDATION;
    address public owner;

    event PositionCheck(
        uint256 borrowed,
        uint256 collateral,
        uint256 collateralPrice,
        uint256 collateralValue,
        uint256 ltv,
        bool isLiquidatable,
        uint256 suggestedAmount
    );

    constructor(address _preLiquidation) {
        PRELIQUIDATION = _preLiquidation;
        owner = msg.sender;
    }

    function simulateProfitability(bytes32 marketId, address borrower) public view returns (
        uint256 repayAmount,
        uint256 seizedAmount,
        uint256 flashLoanFee,
        uint256 netProfit
    ) {
        IMorpho.MarketParams memory marketParams = IMorpho(MORPHO).idToMarketParams(marketId);
        IMorpho.Position memory pos = IMorpho(MORPHO).position(marketId, borrower);
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);

        uint256 borrowed = uint256(pos.borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
        uint256 collateral = uint256(pos.collateral);

        if (borrowed == 0 || collateral == 0) {
            console.log("No position found for profitability simulation");
            return (0, 0, 0, 0);
        }

        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        uint256 collateralValue = collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE);
        uint256 ltv = borrowed.wDivUp(collateralValue);

        uint256 liqThreshold = 85 * 1e16; // 85% in WAD
        if (ltv <= liqThreshold) {
            console.log("Position not liquidatable, LTV:", ltv / 1e16);
            return (0, 0, 0, 0);
        }

        // Fetch pre-liquidation parameters
        uint256 preLltv = 70 * 1e16; // Default: 70%
        uint256 preLIF1 = 105 * 1e16; // Default: 105%
        uint256 preLIF2 = 10825 * 1e14; // Default: 108.25%
        if (PRELIQUIDATION != address(0)) {
            PreLiquidationParams memory params = IPreLiquidation(PRELIQUIDATION).preLiquidationParams();
            preLltv = params.preLltv;
            preLIF1 = params.preLIF1;
            preLIF2 = params.preLIF2;
        }

        uint256 lltv = marketParams.lltv;
        uint256 quotient = (ltv - preLltv).wDivDown(lltv - preLltv);
        uint256 preLIF = quotient.wMulDown(preLIF2 - preLIF1) + preLIF1;

        repayAmount = (borrowed * 1927) / 10000;
        seizedAmount = repayAmount.wMulDown(preLIF);
        flashLoanFee = (repayAmount * 9) / 10000;
        netProfit = seizedAmount > (repayAmount + flashLoanFee) ? seizedAmount - repayAmount - flashLoanFee : 0;

        console.log("Simulated Repay Amount (DAI):", repayAmount / 1e18);
        console.log("Simulated Seized Amount (DAI):", seizedAmount / 1e18);
        console.log("Flash Loan Fee (DAI):", flashLoanFee / 1e18);
        console.log("Net Profit (DAI):", netProfit / 1e18);

        return (repayAmount, seizedAmount, flashLoanFee, netProfit);
    }

    function checkPosition(bytes32 marketId, address borrower) public view returns (bool isLiquidatable, uint256 suggestedAmount) {
        IMorpho.MarketParams memory marketParams = IMorpho(MORPHO).idToMarketParams(marketId);
        IMorpho.Position memory pos = IMorpho(MORPHO).position(marketId, borrower);

        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 borrowed = uint256(pos.borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
        uint256 collateral = uint256(pos.collateral);

        console.log("Borrow Shares:", pos.borrowShares);
        console.log("Collateral (raw):", collateral);
        console.log("Borrowed (raw):", borrowed);
        console.log("Borrowed in DAI:", borrowed / 1e18);

        if (borrowed == 0 || collateral == 0) {
            console.log("No position found");
            return (false, 0);
        }

        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        console.log("Oracle Price (raw):", collateralPrice);

        uint256 collateralValue = collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE);
        console.log("Collateral Value (raw):", collateralValue);
        console.log("Collateral Value in DAI:", collateralValue / 1e18);

        uint256 ltv = borrowed.wDivUp(collateralValue);
        uint256 liqThreshold = 85 * 1e16; // 85% in WAD

        console.log("LTV (raw):", ltv);
        console.log("LTV %:", ltv / 1e16);

        isLiquidatable = ltv > liqThreshold;
        if (isLiquidatable) {
            suggestedAmount = (borrowed * 1927) / 10000;
            console.log("Suggested Liquidation Amount:", suggestedAmount / 1e18);
        }

        return (isLiquidatable, suggestedAmount);
    }

    function executePreliquidation(bytes32 marketId, address targetBorrower) external {
        require(msg.sender == owner, "Not owner");
        (bool canLiquidate, uint256 amount) = checkPosition(marketId, targetBorrower);
        require(canLiquidate, "Position not liquidatable");

        IPool(AAVE_POOL).flashLoanSimple(
            address(this),
            DAI,
            amount,
            abi.encode(marketId, targetBorrower),
            0
        );
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == AAVE_POOL, "Caller must be pool");
        require(asset == DAI, "Unsupported asset");

        (bytes32 marketId, address borrower) = abi.decode(params, (bytes32, address));
        IMorpho.MarketParams memory marketParams = IMorpho(MORPHO).idToMarketParams(marketId);

        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 repaidShares = totalBorrowShares > 0 ? (amount * totalBorrowShares) / totalBorrowAssets : 0;

        IERC20(DAI).approve(PRELIQUIDATION, amount);
        IPreLiquidation(PRELIQUIDATION).preLiquidate(
            borrower,
            0,
            repaidShares,
            ""
        );

        uint256 amountOwed = amount + premium;
        IERC20(DAI).approve(AAVE_POOL, amountOwed);
        return true;
    }

    function recoverToken(address token) external {
        require(msg.sender == owner, "Not owner");
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(owner, balance);
    }
}

contract DeployTrader is Script {
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    // Replace with the actual PreLiquidation address for MARKET_ID
    address constant PRELIQUIDATION = 0xYourExistingPreLiquidationAddress;

    function run() external {
        bytes32 MARKET_ID = 0x5e3e6b1e01c5708055548d82d01db741e37d03b948a7ef9f3d4b962648bcbfa7;
        address targetBorrower = 0x9e0457B5BcD95F4e2fc7FabCC41faAD0D443B4F7;

        console.log("\nReading market data for ID:", vm.toString(MARKET_ID));
        IMorpho.MarketParams memory params = IMorpho(MORPHO).idToMarketParams(MARKET_ID);

        console.log("\nMarket Parameters:");
        console.log("Loan Token:", params.loanToken);
        console.log("Collateral Token:", params.collateralToken);
        console.log("Oracle:", params.oracle);
        console.log("IRM:", params.irm);
        console.log("LLTV:", params.lltv);

        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets, uint256 totalBorrowShares, uint256 lastUpdate,) = IMorpho(MORPHO).market(MARKET_ID);
        console.log("\nMarket State Raw Values:");
        console.log("Total Supply:", totalSupplyAssets);
        console.log("Total Borrow:", totalBorrowAssets);
        console.log("Last Update:", lastUpdate);

        console.log("\nChecking position for:", targetBorrower);

        vm.startBroadcast();
        MorphoTrader trader = new MorphoTrader(PRELIQUIDATION);
        console.log("\nMorphoTrader deployed at:", address(trader));

        try trader.checkPosition(MARKET_ID, targetBorrower) returns (bool, uint256) {
        } catch {
            console.log("Position query reverted");
        }

        console.log("\nSimulating profitability for:", targetBorrower);
        try trader.simulateProfitability(MARKET_ID, targetBorrower) returns (
            uint256 repayAmount,
            uint256 seizedAmount,
            uint256 flashLoanFee,
            uint256 netProfit
        ) {
        } catch {
            console.log("Profitability simulation reverted");
        }

        vm.stopBroadcast();
    }
}