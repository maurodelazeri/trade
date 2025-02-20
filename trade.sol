// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.10;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IOracle} from "../lib/morpho-blue/src/interfaces/IOracle.sol";
import {MathLib} from "../lib/morpho-blue/src/libraries/MathLib.sol";

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

interface IPreLiquidation {
    function preLiquidate(address borrower, uint256 seizedAssets, uint256 repaidShares, bytes calldata data) external returns (uint256, uint256);
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

    function checkPosition(bytes32 marketId, address borrower) public view returns (bool isLiquidatable, uint256 suggestedAmount) {
        IMorpho.MarketParams memory marketParams = IMorpho(MORPHO).idToMarketParams(marketId);
        IMorpho.Position memory pos = IMorpho(MORPHO).position(marketId, borrower);

        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares,,) = IMorpho(MORPHO).market(marketId);
        uint256 borrowed = totalBorrowShares > 0 ? (uint256(pos.borrowShares) * totalBorrowAssets) / totalBorrowShares : 0;
        uint256 collateral = uint256(pos.collateral);

        console.log("Borrow Shares:", pos.borrowShares);
        console.log("Collateral:", collateral);
        console.log("Borrowed Assets (estimated):", borrowed);

        if (borrowed == 0 || collateral == 0) {
            console.log("No active position for borrower");
            return (false, 0);
        }

        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        uint256 collateralValue = (collateral * collateralPrice) / 1e18;
        uint256 ltv = borrowed.wMulDown(1e18).wDivDown(collateralValue);

        isLiquidatable = ltv > 0.85e18;
        if (isLiquidatable) {
            suggestedAmount = (borrowed * 1927) / 10000; // 19.27%
        }

        console.log("Price:", collateralPrice);
        console.log("Collateral Value:", collateralValue);
        console.log("LTV:", ltv);
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

        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares, uint256 lastUpdate,) = IMorpho(MORPHO).market(MARKET_ID);
        console.log("\nMarket State Raw Values:");
        console.log("Total Supply:", totalBorrowAssets); // Fix this to totalSupplyAssets if intended
        console.log("Total Borrow:", totalBorrowAssets);
        console.log("Last Update:", lastUpdate);

        console.log("\nChecking position for:", targetBorrower);

        vm.startBroadcast();
        address PRELIQUIDATION = address(0);
        MorphoTrader trader = new MorphoTrader(PRELIQUIDATION);
        console.log("\nMorphoTrader deployed at:", address(trader));

        try trader.checkPosition(MARKET_ID, targetBorrower) returns (bool, uint256) {
        } catch {
            console.log("Position query reverted");
        }

        vm.stopBroadcast();
    }
}