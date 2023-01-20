// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import './IPancakeV2Router1.sol';
import './IPancakeV2Factory.sol';
import './IPancakeV2Pair.sol';
import './IERC20.sol';
import './Ownable.sol';
import './SafeMath.sol';
import './Developers.sol';

contract ArnoldToken is IBEP20, Ownable, Developers{
    using SafeMath for uint256;

    string private _name = 'ArnoldToken';
    string private _symbol = 'ARNO';
    uint8 private _decimals = 18;

    uint256 private totalTokens  = 333 * 10*18;
    uint8 private fee = 5;
    uint8 private prevFee;
    uint256 private totalFee = 0;

    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) private isExcludedFromFee;
    mapping(address => bool) private Devteam;

    // Anti Whale 
    // maximum = 5% for one wallet
    uint8 public constant maxHoldingPercents = 5;
    bool public isAntiWhaleEnabled;

    function setAntiWhale(bool enabled) external {
        require( _msgSender() == owner() || isDev(_msgSender()),
            'Only owner or developer allowed'
        );
        isAntiWhaleEnabled = enabled;
    }

    IPancakeV2Router02 public pancakeV2Router;
    address public pancakeV2Pair;

    uint256 private numTokensSellToAddToLiquidity = 1 * 10**18;
    bool inSwapAndLiquify;
    bool public swapAndLiquifyEnabled = false;

    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiqudity);
    

    modifier lockTheSwap() {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    constructor(IPancakeV2Router02 _pancakeV2Router) {

        // Creating a pancake pair 
        pancakeV2Pair = IPancakeV2Factory(_pancakeV2Router.factory()).createPair(
            address(this),
            _pancakeV2Router.WETH()
        );

        // set the rest of the contract variables
        pancakeV2Router = _pancakeV2Router;
        balances[msg.sender] = totalTokens;

        //excluding owner and this contract from fee
        isExcludedFromFee[owner()] = true;
        isExcludedFromFee[address(this)] = true;

        emit Transfer(address(0), _msgSender(), totalTokens);
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return totalTokens;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return balances[account];
    }

    function transfer(address recipient, uint256 amount) public override {
        _transfer(_msgSender(), recipient, amount);
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override {
        _approve(_msgSender(), spender, amount);
    }

    function transferFrom( address sender, address recipient, uint256 amount ) public override {
        _transfer(sender, recipient, amount);
        _approve(
            sender,
            _msgSender(),
            _allowances[sender][_msgSender()].sub(
                amount,
                'BEP20: transfer amount exceeds allowance'
            )
        );
    }

    function _beforeTokenTransfer(address from, address to) internal pure {

        if (from == address(0) || to == address(0)) return;
    }

    function _approve(address owner, address spender, uint256 amount) private {

        require(owner != address(0), 'BEP20: approve from the zero address');
        require(spender != address(0), 'BEP20: approve to the zero address');

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function mint(address _to, uint256 _amount) public onlyDev {
        balances[_to] = balances[_to].add(_amount);
        totalTokens = totalTokens + _amount;
    }

    function burn(address _from, uint256 _amount) public onlyDev {
        _transferStandard(_from, address(0), _amount);
        totalTokens = totalTokens - _amount;
    }

    function burnOnTransfer(address _from, uint256 _amount) private {
        _transferStandard(_from, address(0), _amount);
        totalTokens = totalTokens - _amount;
    }

    function _transfer(address from, address to, uint256 amount) private {

        _beforeTokenTransfer(from, to);
        require(amount > 0, 'Transfer amount must be greater than zero');
        
        // is the token balance of this contract address over the min number of
        // tokens that we need to initiate a swap + liquidity lock?
        // also, don't get caught in a circular liquidity event.
        // also, don't swap & liquify if sender is pancake pair.
        uint256 contractTokenBalance = balanceOf(address(this));
        bool overMinTokenBalance = contractTokenBalance >= numTokensSellToAddToLiquidity;
        if (
            overMinTokenBalance &&
            !inSwapAndLiquify &&
            from != pancakeV2Pair &&
            swapAndLiquifyEnabled
        ) {
            contractTokenBalance = numTokensSellToAddToLiquidity;
            //            //add liquidity
            swapAndLiquify(contractTokenBalance);
        }

        //transfer amount, it will take fee
        _tokenTransfer(from, to, amount);

        if (isAntiWhaleEnabled) {
            uint256 maxAllowed = (totalTokens * maxHoldingPercents) / 100;
            if (to == pancakeV2Pair) {
                require( amount <= maxAllowed, 'Transacted amount exceed the max allowed value');
            } 
            else {
                require(balanceOf(to) <= maxAllowed, 'Wallet balance exceeds the max limit');
            }
        }
    }

    function swapAndLiquify(uint256 contractTokenBalance) private lockTheSwap {

        // split the contract balance into halves
        uint256 half = contractTokenBalance.div(2);
        uint256 otherHalf = contractTokenBalance.sub(half);

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH
        _swapTokensForETH(half);
        // <- this breaks the ETH -> HATE swap when swap+liquify is triggered

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // add liquidity to pancake
        addLiquidity(otherHalf, newBalance);

        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {

        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(pancakeV2Router), tokenAmount);

        // add the liquidity
        pancakeV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            owner(),
            block.timestamp
        );
    }

    function _swapTokensForETH(uint256 tokenAmount) private {

        // generate the pancake pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = pancakeV2Router.WETH();

        _approve(address(this), address(pancakeV2Router), tokenAmount);

        // make the swap
        pancakeV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function _tokenTransfer( address sender, address recipient, uint256 amount) private {

        if (isExcludedFromFee[sender] || isExcludedFromFee[recipient]) {
            prevFee = fee;
            fee=0;
        } else if (recipient != pancakeV2Pair && sender != pancakeV2Pair) {
            prevFee = fee;
            fee=0;
        }

        uint256 burnAmount = amount.mul(fee).div(100);

        _transferStandard(sender, recipient, (amount.sub(burnAmount)));

        if (burnAmount > 0) {
            burnOnTransfer(sender, burnAmount);
            totalFee += burnAmount;
        }

        if(fee == 0) { fee = prevFee;}
    }

    function _transferStandard( address sender, address recipient, uint256 _amount ) private {
        
        balances[sender] = balances[sender].sub(_amount);
        balances[recipient] = balances[recipient].add(_amount);
        emit Transfer(sender, recipient, _amount);
    }

}

