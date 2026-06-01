// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ITokenMessenger} from "src/interfaces/ITokenMessenger.sol";

/// @dev Minimal mintable ERC20 standing in for USDC / input tokens (6 decimals).
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _decimals = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mock of CCTP v2 TokenMessengerV2. Records the last depositForBurn args and "burns"
/// (pulls) the amount from the caller so allowance/balance assertions behave like the real flow.
contract MockTokenMessengerV2 is ITokenMessenger {
    struct Call {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        bool withHook;
        bytes hookData;
    }

    Call public last;
    uint256 public callCount;

    /// @dev Explicit getter for the dynamic `hookData` field (omitted from the auto struct getter).
    function lastHookData() external view returns (bytes memory) {
        return last.hookData;
    }

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external override {
        last = Call(
            amount,
            destinationDomain,
            mintRecipient,
            burnToken,
            destinationCaller,
            maxFee,
            minFinalityThreshold,
            false,
            ""
        );
        ++callCount;
        // Simulate the burn by pulling the approved amount from the relayer.
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
    }

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external override {
        last = Call(
            amount,
            destinationDomain,
            mintRecipient,
            burnToken,
            destinationCaller,
            maxFee,
            minFinalityThreshold,
            true,
            hookData
        );
        ++callCount;
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
    }
}

/// @dev Mock of CCTP v2 MessageTransmitterV2.receiveMessage with a configurable return value.
contract MockMessageTransmitterV2 {
    bool public nextSuccess = true;
    uint256 public received;

    function setNextSuccess(bool s) external {
        nextSuccess = s;
    }

    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        ++received;
        return nextSuccess;
    }
}

/// @dev Mock swap router: optionally pulls an input ERC20, mints USDC to the caller (relayer),
/// and optionally refunds some native ETH to simulate dust.
contract MockSwapRouter {
    MockERC20 public immutable usdc;
    uint256 public usdcOut;
    uint256 public ethRefund;
    address public inputToken;
    uint256 public inputPull;

    constructor(MockERC20 _usdc) {
        usdc = _usdc;
    }

    function configure(uint256 _usdcOut, uint256 _ethRefund, address _inputToken, uint256 _inputPull) external {
        usdcOut = _usdcOut;
        ethRefund = _ethRefund;
        inputToken = _inputToken;
        inputPull = _inputPull;
    }

    function swap() external payable {
        if (inputToken != address(0)) {
            IERC20(inputToken).transferFrom(msg.sender, address(this), inputPull);
        }
        usdc.mint(msg.sender, usdcOut);
        if (ethRefund != 0) {
            (bool ok,) = msg.sender.call{value: ethRefund}("");
            require(ok, "refund failed");
        }
    }

    receive() external payable {}
}
