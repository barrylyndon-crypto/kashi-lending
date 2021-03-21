// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
import "@boringcrypto/boring-solidity/contracts/libraries/BoringMath.sol";
import "@sushiswap/core/contracts/uniswapv2/interfaces/IUniswapV2Factory.sol";
import "@sushiswap/core/contracts/uniswapv2/interfaces/IUniswapV2Pair.sol";
import "../interfaces/ISwapper.sol";
import "@sushiswap/bentobox-sdk/contracts/IBentoBoxV1.sol";

contract SushiSwapViaETHSwapper is ISwapper {
    using BoringMath for uint256;

    // Local variables
    IBentoBoxV1 public immutable bentoBox;
    IUniswapV2Factory public immutable factory;
    IERC20 public immutable WETH;
    bytes32 public pairCodeHash;

    constructor(
        IBentoBoxV1 bentoBox_,
        IUniswapV2Factory factory_,
        bytes32 pairCodeHash_,
        IERC20 WETH_
    ) public {
        bentoBox = bentoBox_;
        factory = factory_;
        pairCodeHash = pairCodeHash_;
        WETH = WETH_;
    }

    // Given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        uint256 amountInWithFee = amountIn.mul(997);
        uint256 numerator = amountInWithFee.mul(reserveOut);
        uint256 denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // Given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        uint256 numerator = reserveIn.mul(amountOut).mul(1000);
        uint256 denominator = reserveOut.sub(amountOut).mul(997);
        amountIn = (numerator / denominator).add(1);
    }

    // Swaps to a flexible amount, from an exact input amount
    /// @inheritdoc ISwapper
    function swap(
        IERC20 fromToken,
        IERC20 toToken,
        address recipient,
        uint256 shareToMin,
        uint256 shareFrom
    ) public override returns (uint256 extraShare, uint256 shareReturned) {
        (IERC20 token00, IERC20 token01) = fromToken < WETH ? (fromToken, WETH) : (WETH, fromToken);
        (IERC20 token10, IERC20 token11) = WETH < toToken ? (WETH, toToken) : (toToken, WETH);
        IUniswapV2Pair pair0 =
            IUniswapV2Pair(
                uint256(
                    keccak256(abi.encodePacked(hex"ff", factory, keccak256(abi.encodePacked(address(token00), address(token01))), pairCodeHash))
                )
            );
        IUniswapV2Pair pair1 =
            IUniswapV2Pair(
                uint256(
                    keccak256(abi.encodePacked(hex"ff", factory, keccak256(abi.encodePacked(address(token10), address(token11))), pairCodeHash))
                )
            );

        // Transfer FROM to pair 0 (FROM <-> ETH)
        (uint256 amountFrom, ) = bentoBox.withdraw(fromToken, address(this), address(pair0), 0, shareFrom);

        // Swap FROM to ETH. Transfers to pair 1 (ETH <-> TO)
        (uint256 reserve00, uint256 reserve01, ) = pair0.getReserves();
        uint256 amountETH;
        if (WETH > fromToken) {
            amountETH = getAmountOut(amountFrom, reserve00, reserve01);
            pair0.swap(0, amountETH, address(pair1), "");
        } else {
            amountETH = getAmountOut(amountFrom, reserve01, reserve00);
            pair0.swap(amountETH, 0, address(pair1), "");
        }

        // Swap ETH to TO. Transfers to the Bentobox
        (uint256 reserve10, uint256 reserve11, ) = pair1.getReserves();
        uint256 amountTo;
        if (toToken > WETH) {
            amountTo = getAmountOut(amountETH, reserve10, reserve11);
            pair1.swap(0, amountTo, address(bentoBox), "");
        } else {
            amountTo = getAmountOut(amountETH, reserve11, reserve10);
            pair1.swap(amountTo, 0, address(bentoBox), "");
        }

        (, shareReturned) = bentoBox.deposit(toToken, address(bentoBox), recipient, amountTo, 0);
        extraShare = shareReturned.sub(shareToMin);
    }

    // Swaps to an exact amount, from a flexible input amount
    /// @inheritdoc ISwapper
    function swapExact(
        IERC20 fromToken,
        IERC20 toToken,
        address recipient,
        address refundTo,
        uint256 shareFromSupplied,
        uint256 shareToExact
    ) public override returns (uint256 shareUsed, uint256 shareReturned) {
        (IERC20 token00, IERC20 token01) = fromToken < WETH ? (fromToken, WETH) : (WETH, fromToken);
        (IERC20 token10, IERC20 token11) = WETH < toToken ? (WETH, toToken) : (toToken, WETH);
        IUniswapV2Pair pair0 =
            IUniswapV2Pair(
                uint256(
                    keccak256(abi.encodePacked(hex"ff", factory, keccak256(abi.encodePacked(address(token00), address(token01))), pairCodeHash))
                )
            );
        IUniswapV2Pair pair1 =
            IUniswapV2Pair(
                uint256(
                    keccak256(abi.encodePacked(hex"ff", factory, keccak256(abi.encodePacked(address(token10), address(token11))), pairCodeHash))
                )
            );
            
        // Calculate all the amounts first.
        // This has got to be easier than doing flash swaps:
        uint256 amountToExact = bentoBox.toAmount(toToken, shareToExact, true);

        // See how much ETH we need to swap to get the desired amount.
        // We will do the actual swap once we know how much fromToken we need to get it:
        uint256 amountETH;
        (uint256 reserve10, uint256 reserve11, ) = pair1.getReserves();
        if (toToken > WETH) {
            amountETH = getAmountIn(amountToExact, reserve10, reserve11);
        } else {
            amountETH = getAmountIn(amountToExact, reserve11, reserve10);
        }

        // Once we know how much FROM we need, send it to the FROM <-> ETH pair,
        // and swap it for ETH. Send the ETH to the ETH <-> TO pair:
        uint256 amountFrom;
        (uint256 reserve00, uint256 reserve01, ) = pair0.getReserves();
        if (fromToken > WETH) {
            amountFrom = getAmountIn(amountETH, reserve00, reserve01);
            (, shareUsed) = bentoBox.withdraw(fromToken, address(this), address(pair0), amountFrom, 0);
            pair0.swap(0, amountToExact, address(pair1), "");
        } else {
            amountFrom = getAmountIn(amountETH, reserve01, reserve00);
            (, shareUsed) = bentoBox.withdraw(fromToken, address(this), address(pair0), amountFrom, 0);
            pair0.swap(amountToExact, 0, address(pair1), "");
        }

        // Swap the ETH that we just sent to TO, and send it to the BentoBox:
        if (toToken > WETH) {
            pair1.swap(0, amountToExact, address(bentoBox), "");
        } else {
            pair1.swap(amountToExact, 0, address(bentoBox), "");
        }

        bentoBox.deposit(toToken, address(bentoBox), recipient, 0, shareToExact);
        shareReturned = shareFromSupplied.sub(shareUsed);
        if (shareReturned > 0) {
            bentoBox.transfer(fromToken, address(this), refundTo, shareReturned);
        }
    }
}
