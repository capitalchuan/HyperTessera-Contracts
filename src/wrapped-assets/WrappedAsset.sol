// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title WrappedAsset
/// @notice Minimal ERC-20 representing a locked RWA token position.
///         Deployed once per assetId by ReservePSM.deployWrappedToken. PSM is the exclusive
///         minter and burner; all other transfers are unrestricted.
contract WrappedAsset {
    // -----------------------------------------------------------------------
    // ERC-20 metadata
    // -----------------------------------------------------------------------

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    /// @notice The ReservePSM that deployed this token; only it may mint/burn.
    address public immutable psm;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // -----------------------------------------------------------------------
    // Events / errors
    // -----------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error OnlyPSM();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(address _psm, string memory _name, string memory _symbol, uint8 _decimals) {
        if (_psm == address(0)) revert ZeroAddress();
        psm = _psm;
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    // -----------------------------------------------------------------------
    // PSM-gated mint / burn
    // -----------------------------------------------------------------------

    function mint(address to, uint256 amount) external {
        if (msg.sender != psm) revert OnlyPSM();
        _totalSupply += amount;
        unchecked {
            _balances[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != psm) revert OnlyPSM();
        uint256 bal = _balances[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] = bal - amount;
            _totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    // -----------------------------------------------------------------------
    // ERC-20 standard
    // -----------------------------------------------------------------------

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                _allowances[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 bal = _balances[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] = bal - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
