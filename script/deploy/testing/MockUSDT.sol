// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title MockUSDT
/// @notice **TESTING SCAFFOLD ONLY — NOT a deliverable contract.**
///         Minimal ERC-20 stand-in for USDT on Anvil and public testnets, with an open `mint` so
///         test wallets can be funded. `transfer` deliberately returns nothing, mirroring real
///         USDT's non-standard signature, so integrations that mishandle it fail here rather than
///         in production.
/// @dev    Deployed only under `DEPLOY_PROFILE=demo`; the `production` profile requires `USDT` to
///         name a real token.
contract MockUSDT {
    string public name = "Mock USDT";
    string public symbol = "USDT";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function transfer(address to, uint256 amount) external {
        _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 all = allowance[from][msg.sender];
        if (all != type(uint256).max) {
            require(all >= amount, "MockUSDT: allowance");
            allowance[from][msg.sender] = all - amount;
        }
        _move(from, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "MockUSDT: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
