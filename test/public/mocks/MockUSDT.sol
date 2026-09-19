// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title MockUSDT
/// @notice Non-standard USDT mock for testing: `transfer` and `transferFrom` do NOT return bool,
///         mirroring real USDT behaviour. Mint-to-anyone so tests can freely fund addresses.
/// @dev    Intentionally breaks ERC-20 return-value convention so SafeERC20 usage is exercised.
///         6-decimal precision matches all protocol USDT amounts.
contract MockUSDT {
    // -----------------------------------------------------------------------
    // Storage (manual ERC-20 without inheriting OZ ERC20, so we control ABI)
    // -----------------------------------------------------------------------

    string public name = "Mock USDT";
    string public symbol = "USDT";
    uint8 public decimals = 6;

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // -----------------------------------------------------------------------
    // Non-standard transfer / transferFrom — NO bool return (mimics real USDT)
    // -----------------------------------------------------------------------

    /// @notice Transfers `amount` tokens to `to`. Does NOT return bool (non-standard USDT).
    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    /// @notice Transfers `amount` tokens from `from` to `to`. Does NOT return bool (non-standard USDT).
    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "MockUSDT: insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
    }

    // -----------------------------------------------------------------------
    // Standard approve (returns bool — USDT does implement this)
    // -----------------------------------------------------------------------

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    // -----------------------------------------------------------------------
    // Mint — open to anyone for test convenience
    // -----------------------------------------------------------------------

    /// @notice Mint `amount` tokens to `to`. No access control — tests only.
    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "MockUSDT: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
