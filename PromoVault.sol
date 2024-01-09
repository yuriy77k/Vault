// SPDX-License-Identifier: No License (None)
pragma solidity 0.8.19;

// helper methods for interacting with ERC20 tokens and sending ETH that do not consistently return true/false
library TransferHelper {
    function safeApprove(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('approve(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: APPROVE_FAILED');
    }


    function safeTransfer(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FAILED');
    }


    function safeTransferFrom(address token, address from, address to, uint value) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FROM_FAILED');
    }


    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'TransferHelper: ETH_TRANSFER_FAILED');
    }
}

abstract contract Ownable {
    address internal _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

contract PromoVault is Ownable {
    using TransferHelper for address;
    address public authority;   // address of authority (backend) which sign token transfer data
    mapping(address user => uint256 nonce) public nonces;   // returns nonce for specific user

    event VaultTransfer(address indexed token, address indexed from, address to, uint256 value);
    event Rescue(address _token, uint256 _amount);

    bool public isPaused;

    modifier isNotPaused() {
        require(!isPaused, "is paused");
        _;
    }

    function setPause(bool pause) external onlyOwner {
        isPaused = pause;
    }

/*
// to sign message on the server-side use:

var vault = new web3.eth.Contract(VaultContractABI, VaultContractAddress);
var nonce = await vault.methods.nonces(from).call();
var messageHash = web3.utils.soliditySha3(token, from, to, value, nonce, ChainId, VaultContractAddress);
var signature = web3.eth.accounts.sign(messageHash, PrivateKey);
*/
    // transfer promo tokens from vault.
    function vaultTransfer(
        address token, // token to transfer
        address from, // transfer from user's virtual account
        address to, // transfer to address
        uint256 value, // amount of tokens to transfer
        bytes memory signature
    ) external isNotPaused {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                token,
                from,
                to,
                value,
                nonces[from],
                block.chainid,
                address(this)
            )
        );
        messageHash = prefixed(messageHash);
        require(authority == recoverSigner(messageHash, signature), "wrong signature");
        nonces[from]++;
        token.safeTransfer(to, value);
        emit VaultTransfer(token, from, to, value);

    }

    function setAuthority(address _authority) external onlyOwner {
        require(_authority != address(0));
        authority = _authority;
    }

    function splitSignature(bytes memory sig)
        internal
        pure
        returns (
            uint8 v,
            bytes32 r,
            bytes32 s
        )
    {
        require(sig.length == 65);
        assembly {
            // first 32 bytes, after the length prefix
            r := mload(add(sig, 32))
            // second 32 bytes
            s := mload(add(sig, 64))
            // final byte (first byte of the next 32 bytes)
            v := byte(0, mload(add(sig, 96)))
        }
    }

    function recoverSigner(bytes32 message, bytes memory sig)
        internal
        pure
        returns (address)
    {
        uint8 v;
        bytes32 r;
        bytes32 s;
        (v, r, s) = splitSignature(sig);
        return ecrecover(message, v, r, s);
    }

    // Builds a prefixed hash to mimic the behavior of eth_sign.
    function prefixed(bytes32 hash) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)
            );
    }

    // ERC223 callback
    function tokenReceived(address, uint, bytes calldata) external pure returns(bytes4) {
        return this.tokenReceived.selector;
    }

    // allow owner to rescue tokens from contract
    function rescueTokens(address token, uint256 amount) onlyOwner external {
        if (token == address(0)) {
            msg.sender.safeTransferETH(amount);
        } else {
            token.safeTransfer(msg.sender, amount);
        }
        emit Rescue(token, amount);
    } 
}