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

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract PromoVault2 is Ownable {
    using TransferHelper for address;

    struct Airdrop {
        uint128 balance;    // available airdrop balance
        uint64 vestingDate; // after this date when tokens can be claimed
        uint64 deadline;    // until this date tokens can be claimed 
        address token;      // airdrop token
    }

    mapping(address signer => Airdrop) public airdrops;
    mapping(bytes32 messageHash => bool processed) public isProcessed;   // record processed messages


    event VaultTransfer(address indexed token, address indexed signer, address indexed from, address to, uint256 value, uint256 nonce);
    event CreateAirdrop(address signer, address token, uint256 amount);
    event CloseAirdrop(address signer, address receiver, uint256 amount);
    event Rescue(address _token, uint256 _amount);

    bool public isPaused;

    modifier isNotPaused() {
        require(!isPaused, "is paused");
        _;
    }

    function setPause(bool pause) external onlyOwner {
        isPaused = pause;
    }

    function createAirdrop(
        address token,  // airdrop token
        uint256 amount, // amount of tokens for airdrop
        address signer  // unique signer for this airdrop
    ) external isNotPaused {
        require(signer != address(0) && airdrops[signer].token == address(0), "signer already was used");
        airdrops[signer].token = token;
        uint256 balance = IERC20(token).balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        amount = IERC20(token).balanceOf(address(this)) - balance;
        require(amount < 2**128, "too big amount");
        airdrops[signer].balance = uint128(amount);
        emit CreateAirdrop(signer, token, amount);
    }
/*
// to sign message on the server-side use:

var vault = new web3.eth.Contract(VaultContractABI, VaultContractAddress);
var nonce = await vault.methods.nonces(from).call();
var messageHash = web3.utils.soliditySha3(signer, token, from, value, nonce, ChainId, VaultContractAddress);
var signature = web3.eth.accounts.sign(messageHash, PrivateKey);
*/
    // claim promo tokens from vault to user's address. Can be called by any wallet
    function claimTokens(
        address signer, // signer of airdrop
        address to, // transfer to address (user's address who received airdrop)
        uint256 value, // amount of tokens to transfer
        uint256 nonce, // nonce is used to if you need to airdrop tokens to the same user many times
        bytes memory signature
    ) external isNotPaused {
        claim(signer, to, to, value, nonce, signature);
    }


    // user transfers promo tokens from vault to some address. Must be called by user who received airdrop
    function transferTokens(
        address signer, // signer of airdrop
        address to, // transfer to address (any address)
        uint256 value, // amount of tokens to transfer
        uint256 nonce, // nonce is used to if you need to airdrop tokens to the same user many times
        bytes memory signature
    ) external isNotPaused {
        claim(signer, msg.sender, to, value, nonce, signature);
    }

    function claim(
        address signer, // signer of airdrop
        address from, // transfer from address
        address to, // transfer to address
        uint256 value, // amount of tokens to transfer
        uint256 nonce, // nonce is used to if you need to airdrop tokens to the same user many times
        bytes memory signature        
    ) internal {
        Airdrop memory a = airdrops[signer];
        require(a.token != address(0) && signer != address(0), "closed");
        require(a.balance >= value, "Not enough tokens");
        require(a.vestingDate <= block.timestamp, "under vesting");
        require(a.deadline == 0 || a.deadline >= block.timestamp, "expired");

        bytes32 messageHash = keccak256(
            abi.encodePacked(
                signer,
                a.token,
                from,
                value,
                nonce,
                block.chainid,
                address(this)
            )
        );
        messageHash = prefixed(messageHash);
        require(!isProcessed[messageHash], "already claimed");
        require(signer == recoverSigner(messageHash, signature), "wrong signature");
        isProcessed[messageHash] = true;
        airdrops[signer].balance = a.balance - uint128(value);
        a.token.safeTransfer(to, value);
        emit VaultTransfer(a.token, signer, from, to, value, nonce);
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
/*
    // ERC223 callback
    function tokenReceived(address, uint, bytes calldata) external pure returns(bytes4) {
        return this.tokenReceived.selector;
    }
*/
    // owner can close airdrop before all tokens is claimed and transfer leftover tokens to receiver address
    function closeAirdrop(address signer, address receiver) external onlyOwner {
        Airdrop memory a = airdrops[signer];
        require(a.token != address(0) && signer != address(0), "closed");
        require(a.balance != 0, "Not enough tokens");
        a.token.safeTransfer(receiver, uint256(a.balance));
        airdrops[signer].balance = 0;
        emit CloseAirdrop(signer, receiver, uint256(a.balance));
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