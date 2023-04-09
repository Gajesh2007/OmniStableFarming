// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "./lzApp/NonblockingLzApp.sol";
import "../node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IStargateRouter.sol";

interface StableSwap  {
    function add_liquidity(uint256[1] memory amounts, uint256 min_mint_amount) external;
    function remove_liquidity_one_coin(uint256 _token_amount, uint256 i, uint256 min_amount) external;
}

interface MasterChef {
    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
}

contract Wallet is Ownable {
    // Deposit Token (Stablecoin)
    IERC20 public token;

    // StableSwap Details
    StableSwap public stableSwap;
    IERC20 public stableLP;
    uint256 public balance;
    uint256 public stablePid;

    // MasterChef V2 Details
    MasterChef public masterChef;
    uint256 public pid;
    IERC20 public rewardToken;
    
    uint256 constant MAX = 115792089237316195423570985008687907853269984665640564039457584007913129639935;

    constructor(
        StableSwap _stableSwap,
        IERC20 _stableLP,
        MasterChef _masterChef,
        uint256 _pid,
        IERC20 _token,
        uint256 _stablePid,
        IERC20 _rewardToken
    ) {
        stableSwap = _stableSwap;
        stableLP = _stableLP;
        masterChef = _masterChef;
        pid = _pid;
        token = _token;
        stablePid = _stablePid;
        rewardToken = _rewardToken;
    }

    function deposit(uint256 _pid, uint256 _amount) public onlyOwner {
        token.transferFrom(owner(), address(this), _amount);

        token.approve(address(stableSwap), MAX);

        // balance before
        uint256 _bal = stableLP.balanceOf(address(this));

        // TODO: CHANGE THE ORDER OF AMOUNTS BASED ON THE ASSET
        stableSwap.add_liquidity([_amount], 0);

        // balance after
        uint256 _balAfter = stableLP.balanceOf(address(this));

        balance = balance + (_balAfter - _bal);

        stableLP.approve(address(masterChef), MAX);
        masterChef.deposit(_pid, balance);

        rewardToken.transfer(address(this), rewardToken.balanceOf(address(this)));
    }

    function withdraw(uint256 _pid, uint256 _amount) public onlyOwner {
        masterChef.withdraw(_pid, _amount);

        uint256 _bal = stableLP.balanceOf(address(this));

        stableLP.approve(address(stableSwap), MAX);
        stableSwap.remove_liquidity_one_coin(_bal, stablePid, 0);

        balance = balance - _bal;

        token.transfer(owner(), balance);
    }

    function claim() public onlyOwner {
        masterChef.deposit(pid, 0);

        rewardToken.transfer(owner(), rewardToken.balanceOf(address(this)));
    }
}

contract Destination is NonblockingLzApp {
    IERC20 public token;
    
    // Pool Id of the Destination chain
    uint256 public poolId;

    IStargateRouter public stargateRouter;

    uint256 constant MAX = 115792089237316195423570985008687907853269984665640564039457584007913129639935;

    // StableSwap Details
    StableSwap public stableSwap;
    IERC20 public stableLP;
    uint256 public stablePid;

    // MasterChef V2 Details
    MasterChef public masterChef;
    uint256 public pid;
    IERC20 public rewardToken;

    constructor(
        address _lzEndpoint,            // LayerZero Endpoint
        address _stargateRouter,        // Stargate Router
        uint256 _poolId,                // Stargate Pool Id on Destination Chain
        IERC20 _token,                  // Deposit Token
        MasterChef _masterChef,         // MasterChef V2
        uint256 _pid,                   // MasterChef Pool Id
        StableSwap _stableSwap,         // StableSwap 
        IERC20 _stableLP,               // LP Token of the Stablecoin Pool
        uint256 _stablePid,             // StableSwap Pool Id
        IERC20 _rewardToken             // Reward Token
    ) NonblockingLzApp(_lzEndpoint) {
        token = _token;
        poolId = _poolId;
        stargateRouter = IStargateRouter(_stargateRouter);
        masterChef = _masterChef;
        pid = _pid;
        stableSwap = _stableSwap;
        stableLP = _stableLP;
        stablePid = _stablePid;
        rewardToken = _rewardToken;
    }

    struct User {
        address _add;
        bool _activated;
    }

    struct ChainDetails {
        uint256 _poolId;
        address _allowedAddress;
        bool _activated;
    }

    mapping (address => User) public user;
    mapping (uint256 => ChainDetails) public srcDetails;

    function _nonblockingLzReceive(
        uint16 _srcChainId, 
        bytes memory _srcAddress, 
        uint64 _nonce, 
        bytes memory _payload
    ) internal override {
        address extractedAddress;
        assembly {
            extractedAddress := mload(add(_srcAddress, 20))
        }

        (string memory message, address userAddress, uint256 amount) = abi.decode(_payload, (string, address, uint256));

        if (keccak256(bytes(message)) == keccak256(bytes("withdraw"))) {
            require(srcDetails[_srcChainId]._activated == true, "this chain is not allowed");
            require(extractedAddress == srcDetails[_srcChainId]._allowedAddress, "requests are not allowed from this address");

            Wallet wallet = Wallet(user[userAddress]._add);
            wallet.withdraw(pid, amount);

            uint256 amountToSend = token.balanceOf(address(this));

            // Stargate's Router.swap() function sends the tokens to the destination chain.
            stargateRouter.swap{value: 0.03 ether}(
                _srcChainId,                                     // the destination chain id
                poolId,                                          // the source Stargate poolId
                srcDetails[_srcChainId]._poolId,                // the destination Stargate poolId
                payable(msg.sender),                            // refund adddress. if msg.sender pays too much gas, return extra eth
                amountToSend,                                   // total tokens to send to destination chain
                0,                                              // min amount allowed out
                IStargateRouter.lzTxObj(200000, 0, "0x"),       // default lzTxObj
                abi.encodePacked(userAddress),                  // destination address
                abi.encodePacked()                              // bytes payload
            );

            rewardToken.transfer(userAddress, rewardToken.balanceOf(address(this)));
        } else if (keccak256(bytes(message)) == keccak256(bytes("claim"))) {
            Wallet wallet = Wallet(user[userAddress]._add);
            wallet.claim();

            rewardToken.transfer(userAddress, rewardToken.balanceOf(address(this)));
        } else if (keccak256(bytes(message)) == keccak256(bytes("claim_bridge"))) {
            // TBD
        }
    }

    function sgReceive(
        uint16 _chainId, 
        bytes memory _srcAddress, 
        uint _nonce, 
        address _token, 
        uint amountLD, 
        bytes memory _payload
    ) external {
        require(address(token) == _token, "Invalid Token");

        (address _add) = abi.decode(_payload, (address));
        
        if (user[_add]._activated == true) {
            Wallet wallet = Wallet(user[_add]._add);
            wallet.deposit(pid, amountLD);
        } else if (user[_add]._activated == false) {
            Wallet wallet = new Wallet(
                stableSwap,
                stableLP,
                masterChef,
                pid,
                token,
                stablePid,
                rewardToken
            );

            user[_add]._add = address(wallet);
            user[_add]._activated = true; 

            wallet.deposit(pid, amountLD);
        }
    }

    // Getter Functions


    function estimateFee(uint16 _dstChainId, bool _useZro, bytes memory PAYLOAD, bytes calldata _adapterParams) public view returns (uint nativeFee, uint zroFee) {
        return lzEndpoint.estimateFees(_dstChainId, address(this), PAYLOAD, _useZro, _adapterParams);
    }

    receive() external payable {}
}
