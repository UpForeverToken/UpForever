pragma solidity 0.6.12;

import "./libs/IUniswapV2Router02.sol";
import "./libs/IUniswapV2Pair.sol";
import "./libs/IUniswapV2Factory.sol";
import "./libs/BEP20.sol";

contract TestUp is BEP20 {
    // Transfer tax rate in basis points.
    uint16 public transferTaxRate = 990;
    // Max transfer tax rate: 15%.
    uint16 public constant MAXIMUM_TRANSFER_TAX_RATE = 1500;
    // Automatic swap and liquify enabled
    bool public swapAndLiquifyEnabled = false;
    // Min amount to liquify - initially at 1/1000th of the starting supply
    uint256 public minAmountToLiquify = 1000000 ether;
    // Burn address
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    IUniswapV2Router02 public router;
    // The trading pair
    address public pair;
    // In swap and liquify
    bool private _inSwapAndLiquify;
    // Stop the burn
    bool public burnPaused;
    // Burn parameter
    uint public multiplier = 500;
    // The operator can update within bounds the contract's parameters and debug in case of problem
    // The operator doesn't have the hand on rugable parameters.
    address private _operator;
    // Buyback address - should be a contract
    address payable public buyback;
    // PCS Router
    address public pcsRouter;
    // AntiPaperHands
    bool antiPaperHandsActivated;
    // Time trading starts
    uint startTradingTime;
    // AntiPaperHands %
    uint antiPaperHandsPct;
    // When was the last pump?
    uint lastPump;
    // DxSalePresaleFeeWallet
    address DxSalePresaleFeeWallet = 0x548E03C19A175A66912685F71e157706fEE6a04D;
    // marketing wallet
    address payable public mkt;
    // Max transfer amount rate in basis points.
    uint16 public maxTransferAmountRate = 200;
    // Addresses that excluded from antiPaperHands
    mapping(address => bool) public _excludedFromAntiPaperHands;
    mapping(address => bool) public _excludedFromFees;
    mapping(address => bool) public _excludedFromTransferBeforeTradingEnabled;

    // Events
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event TransferTaxRateUpdated(address indexed operator, uint256 previousRate, uint256 newRate);
    event MaxTransferAmountRateUpdated(address indexed operator, uint256 previousRate, uint256 newRate);
    event SwapAndLiquifyEnabledUpdated(address indexed operator, bool enabled);
    event MinAmountToLiquifyUpdated(address indexed operator, uint256 previousAmount, uint256 newAmount);
    event RouterUpdated(address indexed operator, address indexed router, address indexed pair);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiqudity);
    event BurnBabyBurn(uint256 amountBurnt);

    modifier onlyOperator() {
        require(_operator == msg.sender, "operator: caller is not the operator");
        _;
    }

    modifier lockTheSwap {
        _inSwapAndLiquify = true;
        _;
        _inSwapAndLiquify = false;
    }

    modifier transferTaxFree {
        uint16 _transferTaxRate = transferTaxRate;
        transferTaxRate = 0;
        _;
        transferTaxRate = _transferTaxRate;
    }

    modifier antiPaperHands(address sender, address recipient, uint256 amount) {
        // AntiPaperHands only for selling (sad!)
        if (antiPaperHandsActivated && recipient == pair) {
            if (
                _excludedFromAntiPaperHands[sender] == false
                && ( _excludedFromAntiPaperHands[recipient] == false
                || recipient == pair) // Pair isn't excluded if we buy, only if we sell
            ) {
                require(amount <= maxTransferAmount(), "UpForever::antiPaperHands: Transfer amount exceeds the maxTransferAmount");
            }
        }
        _;
    }

    modifier waitForTradingStartTime(address sender, address recipient, uint256 amount) {
        // Prevent trading before presale ends
        if (
            _excludedFromTransferBeforeTradingEnabled[sender] == false
            && _excludedFromTransferBeforeTradingEnabled[recipient] == false
        ) {
            require(block.timestamp > startTradingTime, "UpForever::StartTime: Please wait for the start of trading");
        }
        _;
    }

    /**
     * @notice Constructs the PantherToken contract.
     */
    constructor(uint _startTradingTime, address _pcsRouter, address payable _mkt, address payable _buyback) public BEP20("UpForever", "UPEVER") {

        // Mint initial supply - 1 Billion tokens
        // No minting after this of course
        _mint(msg.sender, 1 * 1e9 * 1e18);
        startTradingTime = _startTradingTime;
        mkt = _mkt;
        buyback = _buyback;
        pcsRouter = _pcsRouter;
        // Whitelist
        whitelist(msg.sender);
        whitelist(buyback);
        whitelist(mkt);
        whitelist(address(0));
        whitelist(address(this));
        whitelist(BURN_ADDRESS);
        whitelist(DxSalePresaleFeeWallet);

        _operator = _msgSender();
        emit OperatorTransferred(address(0), _operator);
    }

    // Owner, not operator, can whitelist.
    function whitelist(address _whitelisted) public onlyOwner {
        _excludedFromAntiPaperHands[_whitelisted] = true;
        _excludedFromFees[_whitelisted] = true;
        _excludedFromTransferBeforeTradingEnabled[_whitelisted] = true;
    }

    event DebugBool(string message, bool n);
    event Debug(string message, uint n);
    /// @dev overrides transfer function to meet tokenomics of TOKEN
    function _transfer(address sender, address recipient, uint256 amount) internal virtual override 
        antiPaperHands(sender, recipient, amount)
        waitForTradingStartTime(sender, recipient, amount) {

        // swap and liquify
        if (
            swapAndLiquifyEnabled == true
            && _inSwapAndLiquify == false
            && address(router) != address(0)
            && pair != address(0)
            && sender != pair
        ) {
            swapAndLiquify();
        }

        
        uint256 taxAmount;
        // If Burn or no tax = no tax
        if (recipient == address(0)
            || transferTaxRate == 0
            || _excludedFromFees[sender]
            || _excludedFromFees[recipient]
            ) {
            super._transfer(sender, recipient, amount);
        } else {

            // We compute the tax
            // Normal tax when buying
            taxAmount = amount.mul(transferTaxRate).div(10000);
            // When selling, the tax is higher (x1.5)
            if (recipient==pair) {
                taxAmount = amount.mul(transferTaxRate).div(20000).mul(3);
            }

            // How much should we send?
            uint256 sendAmount = amount.sub(taxAmount);
            require(amount == sendAmount + taxAmount, "UpForever::transfer: Tax value invalid");
            // We send the token
            super._transfer(sender, address(this), taxAmount);
            super._transfer(sender, recipient, sendAmount);
            amount = sendAmount;
        }

        // Only triggered if the pair is not 0, burn is not paused and the sender or the recipiend is the pair
        if (pair != address(0) && !burnPaused && recipient == pair) {
            
            uint tokenToBurnInLp = getBurnAmount(amount);
            _burn(pair, tokenToBurnInLp);
            emit BurnBabyBurn(tokenToBurnInLp);
        }
    }

    /// @dev Swap and liquify
    function swapAndLiquify() private lockTheSwap transferTaxFree {
        uint256 contractTokenBalance = balanceOf(address(this));
        uint256 maxTransferAmount = maxTransferAmount();
        contractTokenBalance = contractTokenBalance > maxTransferAmount ? maxTransferAmount : contractTokenBalance;

        if (contractTokenBalance >= minAmountToLiquify) {
            // only min amount to liquify
            uint256 liquifyAmount = minAmountToLiquify;

            // split the liquify amount
            uint256 liquidityTokens = liquifyAmount.div(990).mul(200);

            // capture the contract's current ETH balance.
            // this is so that we can capture exactly the amount of ETH that the
            // swap creates, and not make the liquidity event include any ETH that
            // has been manually sent to the contract
            uint256 initialBalance = address(this).balance;

            // swap tokens for ETH
            swapTokensForEth(liquidityTokens);

            // how much ETH did we just swap into?
            uint256 newBalance = address(this).balance.sub(initialBalance);

            // // add liquidity
            addLiquidity(liquidityTokens, newBalance);
            emit SwapAndLiquify(liquidityTokens, newBalance, liquidityTokens);

            // We have 590/990th tokens left
            // swap tokens for ETH
            initialBalance = address(this).balance;
            // We swap the rest
            swapTokensForEth(liquifyAmount.sub(liquidityTokens.mul(2)));
            // How much eth did we get?
            newBalance = address(this).balance.sub(initialBalance);
            // We send 400/990th tokens to the buyback address
            buyback.transfer(newBalance.div(990).mul(400));
            emit Debug("buyback Send", newBalance.div(990).mul(400));
            // We send 190/990th tokens to the mkt wallet
            emit Debug("marketing Send", address(this).balance);
            mkt.transfer(address(this).balance);
        }
    }

    function getBurnAmount(uint amount) internal returns (uint burnAmount) {
        // We multiply first, then divide to prevent tokenToBurn to go to 0 in most cases
        // if that happens, then the burn will be equal to 0
        // Yeah but what about overflows, heh?
        // Well if you remember your training, you know that max value is 2^256 for a uint
        // Which is equivalent to 1.15*1e77 according to WolframAlpha
        // And max supply is 1e18*1e9 (1 billion token)
        // So (1e18*1e9)**2 < 2^256 and we should be safe
        uint tokenToBurnInLp = amount.mul(balanceOf(pair)).mul(multiplier).div(1000).div(totalSupply());
        return(tokenToBurnInLp);
    }

    /// @dev Swap tokens for eth
    function swapTokensForEth(uint256 tokenAmount) private transferTaxFree {
        // generate the pantherSwap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        _approve(address(this), address(router), tokenAmount);

        // make the swap
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    /// @dev Add liquidity
    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private transferTaxFree {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(router), tokenAmount);

        // add the liquidity
        router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            BURN_ADDRESS, // LPs are burnt - #notasafemoonrug!
            block.timestamp
        );
    }

    // To receive BNB from router when swapping
    receive() external payable {}

    /**
     * @dev Update the transfer tax rate.
     * Can only be called by the current operator.
     */
    function updateTransferTaxRate(uint16 _transferTaxRate) public onlyOperator {
        require(_transferTaxRate <= MAXIMUM_TRANSFER_TAX_RATE, "UpForever::updateTransferTaxRate: Transfer tax rate must not exceed the maximum rate.");
        emit TransferTaxRateUpdated(msg.sender, transferTaxRate, _transferTaxRate);
        transferTaxRate = _transferTaxRate;
    }

    /**
     * @dev Update the min amount to liquify.
     * Can only be called by the current operator.
     */
    function updateMinAmountToLiquify(uint256 _minAmount) public onlyOperator {
        emit MinAmountToLiquifyUpdated(msg.sender, minAmountToLiquify, _minAmount);
        minAmountToLiquify = _minAmount;
    }

    function isExcludedFromAntiPaperHands(address _account) public view returns (bool) {
        return _excludedFromAntiPaperHands[_account];
    }

    function updateMaxTransferAmountRate(uint16 _maxTransferAmountRate) public onlyOperator {
        require(_maxTransferAmountRate <= 10000, "Upforever::updateMaxTransferAmountRate: Max transfer amount rate must not exceed the maximum rate.");
        require(_maxTransferAmountRate >= 5, "Upforever::updateMaxTransferAmountRate: Max transfer amount rate must not be lower thant the minimum rate.");
        emit MaxTransferAmountRateUpdated(msg.sender, maxTransferAmountRate, _maxTransferAmountRate);
        maxTransferAmountRate = _maxTransferAmountRate;
    }

    function setExcludedFromAntiPaperHands(address _account, bool _excluded) public onlyOperator {
        _excludedFromAntiPaperHands[_account] = _excluded;
    }

    /**
     * @dev Returns the max transfer amount.
     */
    function maxTransferAmount() public view returns (uint256) {
        return totalSupply().mul(maxTransferAmountRate).div(10000);
    }

    /**
     * @dev Update the swapAndLiquifyEnabled.
     * Can only be called by the current operator.
     */
    function updateSwapAndLiquifyEnabled(bool _enabled) public onlyOperator {
        emit SwapAndLiquifyEnabledUpdated(msg.sender, _enabled);
        swapAndLiquifyEnabled = _enabled;
    }

    // Update the router and create the pair
    function updateRouter() public onlyOperator {
        router = IUniswapV2Router02(pcsRouter);
        pair = IUniswapV2Factory(router.factory()).getPair(address(this), router.WETH());
        setExcludedFromAntiPaperHands(pair, true);
        require(pair != address(0), "UpForever::updateRouter: Invalid pair address.");
        emit RouterUpdated(msg.sender, address(router), pair);
    }

    function updateBurnPaused(bool _pause) external onlyOperator {
        burnPaused = _pause;
    }

    function updateBuyback(address payable _buyback) external onlyOperator {
        buyback = _buyback;
    }


    function updateMultiplier(uint _multiplier) external onlyOperator {
        multiplier = _multiplier;
    }

    /**
     * @dev Returns the address of the current operator.
     */
    function operator() public view returns (address) {
        return _operator;
    }

    /**
     * @dev Transfers operator of the contract to a new account (`newOperator`).
     * Can only be called by the current operator.
     */
    function transferOperator(address newOperator) public onlyOperator {
        require(newOperator != address(0), "TOKEN::transferOperator: new operator is the zero address");
        emit OperatorTransferred(_operator, newOperator);
        _operator = newOperator;
    }

    // This function allows the operator to pump the token price, because why not?
    // The final pump amount is computed pseudorandomly
    // The exact pump moment will be random as well, in order to prevent any dumping
    // The pump will be done once per day.
    function YouGotToPumpItUp() external onlyOperator {
        // The next pump is at least 12h after the last
        if (block.timestamp> lastPump + 43200) {
            lastPump = block.timestamp;
            uint256 youGotToSingAlong = uint(keccak256(
            abi.encodePacked(block.timestamp, 
            block.coinbase, 
            blockhash(block.number-1), 
            block.gaslimit))) % 20;
        
            uint pairBal = balanceOf(pair);
            _burn(pair, pairBal.mul(youGotToSingAlong).div(100));
        }
    }
}