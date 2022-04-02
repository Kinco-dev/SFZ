// SPDX-License-Identifier: MIT


pragma solidity ^0.8.11;

import "./DividendPayingToken.sol";
import "./SafeMath.sol";
import "./IterableMapping.sol";
import "./Ownable.sol";
import "./IUniswapV2Pair.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Router.sol";
import "./Pausable.sol";

contract SportsFansZone is ERC20, Ownable, Pausable {
    using SafeMath for uint256;

    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;

    bool private _isSwapping;

    SFZDividendTracker public dividendTracker;

    address public liquidityWallet;
    address public marketingWallet = 0xE9AA50c422e9923CD12967245f8c4f43A54009ba;
    address public giftWallet = 0x7f80973fA37E9dB9b2e401cea1d89510ea2E25cE;
    address constant private  DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public maxSellTransactionAmount = 1* 10 ** 12 * (10**9); // 0.1% of supply
    uint256 private _swapTokensAtAmount = 1 * 10 ** 11 * (10**9); // 0.01% of supply

    uint256 public BNBRewardsFee = 2;
    uint256 public liquidityFee = 3;
    uint256 public marketingFee = 3;
    uint256 public giftFee = 2;

    uint256 public totalFees;

    // use by default 300,000 gas to process auto-claiming dividends
    uint256 public gasForProcessing = 300000;

    // timestamp for when the token can be traded freely on PanackeSwap
    uint256 public tradingEnabledTimestamp = 1656626400; // 01/07/2022 00:00:00 GMT+2

    // exclude from max sell transaction amount
    mapping (address => bool) private _isExcludedFromMaxSellTransactionAmount;
    // exclude from fees 
    mapping (address => bool) private _isExcludedFromFees;
    // exclude from transactions
    mapping(address=>bool) private _isBlacklisted;
    // addresses that can make transfers before listing
    mapping (address => bool) private _canTransferBeforeTradingIsEnabled;

    // store addresses that a automatic market maker pairs.
    mapping (address => bool) public automatedMarketMakerPairs;

    event UpdateDividendTracker(address indexed newAddress, address indexed oldAddress);

    event UniswapV2RouterUpdated(address indexed newAddress, address indexed oldAddress);

    event UniswapV2PairUpdated(address indexed newAddress, address indexed oldAddress);

    event ExcludeFromFees(address indexed account, bool isExcluded);

    event ExcludeFromMaxSellTransactionAmount(address indexed account, bool isExcluded);

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    event LiquidityWalletUpdated(address indexed newLiquidityWallet, address indexed oldLiquidityWallet);

    event GasForProcessingUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    event BlackList(address indexed account, bool isBlacklisted);

    event Burn(uint256 amount);

    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiquidity
    );

    event MaxSellTransactionAmountUpdated(uint256 amount);

    event SendHolderDividends(uint256 amount);

    event SendMarketingDividends(uint256 amount);

    event SendGiftDividends(uint256 amount);

    event ProcessedDividendTracker(
    	uint256 iterations,
    	uint256 claims,
        uint256 lastProcessedIndex,
    	bool indexed automatic,
    	uint256 gas,
    	address indexed processor
    );

    constructor() ERC20("sportsfanszone", "SFZ") {

        totalFees = BNBRewardsFee + liquidityFee + marketingFee + giftFee;

    	dividendTracker = new SFZDividendTracker();

    	liquidityWallet = owner();
    	
    	uniswapV2Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
         // Create a uniswap pair for this new token
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
            .createPair(address(this), uniswapV2Router.WETH());

        _setAutomatedMarketMakerPair(uniswapV2Pair, true);

        // exclude from receiving dividends
        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(owner());
        dividendTracker.excludeFromDividends(address(uniswapV2Router));
        dividendTracker.excludeFromDividends(address(marketingWallet));
        dividendTracker.excludeFromDividends(address(giftWallet));

        // exclude from paying fees
        excludeFromFees(liquidityWallet, true);
        excludeFromFees(marketingWallet, true);
        excludeFromFees(giftWallet, true);
        excludeFromFees(address(this), true);

         // exclude from max transaction amount
        excludeFromMaxSellTransactionAmount(owner(),true);

        // enable owner to send tokens before listing on PancakeSwap
        _canTransferBeforeTradingIsEnabled[owner()] = true;

        _mint(owner(), 1 * 10 ** 15 * (10**9));

    }

    receive() external payable {
  	}
    
    function unpause() public onlyOwner {
            _unpause();
    }
    function pause() public onlyOwner  {
            _pause();
    }

    function updateDividendTracker(address newAddress) public onlyOwner {
        require(newAddress != address(dividendTracker), "SFZ: The dividend tracker already has that address");

        SFZDividendTracker newDividendTracker = SFZDividendTracker(payable(newAddress));

        require(newDividendTracker.owner() == address(this), "SFZ: The new dividend tracker must be owned by the SFZ token contract");

        newDividendTracker.excludeFromDividends(address(newDividendTracker));
        newDividendTracker.excludeFromDividends(address(this));
        newDividendTracker.excludeFromDividends(owner());
        newDividendTracker.excludeFromDividends(address(uniswapV2Router));
        newDividendTracker.excludeFromDividends(address(marketingWallet));
        newDividendTracker.excludeFromDividends(address(giftWallet));
        newDividendTracker.excludeFromDividends(address(uniswapV2Pair));

        

        emit UpdateDividendTracker(newAddress, address(dividendTracker));

        dividendTracker = newDividendTracker;
    }

    function updateUniswapRouter(address newAddress) public onlyOwner {
        require(newAddress != address(uniswapV2Router), "SFZ: The router has already that address");
        emit UniswapV2RouterUpdated(newAddress, address(uniswapV2Router));
        uniswapV2Router = IUniswapV2Router02(newAddress);
        dividendTracker.excludeFromDividends(address(newAddress));
    }

    function updateUniswapPair(address newAddress) external onlyOwner {
        require(newAddress != address(uniswapV2Pair), "SFZ: The pair address has already that address");
        emit UniswapV2PairUpdated(newAddress, address(uniswapV2Pair));
        uniswapV2Pair = newAddress;
        _setAutomatedMarketMakerPair(newAddress, true);
    }

    function excludeFromFees(address account, bool excluded) public authorized {
        require(_isExcludedFromFees[account] != excluded, "SFZ: Account is already the value of 'excluded'");
        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    function excludeMultipleAccountsFromFees(address[] memory accounts, bool excluded) public authorized {
        for(uint256 i = 0; i < accounts.length; i++) {
            excludeFromFees(accounts[i],excluded);
        }
    }

    function excludeFromMaxSellTransactionAmount(address account, bool excluded) public authorized {
        require(_isExcludedFromMaxSellTransactionAmount[account] != excluded, "SFZ: Account has already the value of 'excluded'");
        _isExcludedFromMaxSellTransactionAmount[account] = excluded;
        emit ExcludeFromMaxSellTransactionAmount(account,excluded);
    }

    function setAutomatedMarketMakerPair(address pair, bool value) public onlyOwner {
        require(pair != uniswapV2Pair, "SFZ: The PancakeSwap pair cannot be removed from automatedMarketMakerPairs");

        _setAutomatedMarketMakerPair(pair, value);
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        require(automatedMarketMakerPairs[pair] != value, "SFZ: Automated market maker pair is already set to that value");
        automatedMarketMakerPairs[pair] = value;

        if(value) {
            dividendTracker.excludeFromDividends(pair);
        }

        emit SetAutomatedMarketMakerPair(pair, value);
    }


    function updateLiquidityWallet(address newLiquidityWallet) public onlyOwner {
        require(newLiquidityWallet != liquidityWallet, "SFZ: The liquidity wallet is already this address");
        excludeFromFees(newLiquidityWallet, true);
        emit LiquidityWalletUpdated(newLiquidityWallet, liquidityWallet);
        liquidityWallet = newLiquidityWallet;
    }

    function updateGasForProcessing(uint256 newValue) public onlyOwner {
        require(newValue >= 100000 && newValue <= 500000, "SFZ: gasForProcessing must be between 200,000 and 500,000");
        require(newValue != gasForProcessing, "SFZ: Cannot update gasForProcessing to same value");
        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    function updateClaimWait(uint256 claimWait) external onlyOwner {
        dividendTracker.updateClaimWait(claimWait);
    }

    function getClaimWait() external view returns(uint256) {
        return dividendTracker.claimWait();
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }

    function isExcludedFromFees(address account) public view returns(bool) {
        return _isExcludedFromFees[account];
    }
    function isExcludedFromDividends(address account) public view returns(bool) {
        return dividendTracker.isExcludedFromDividends(account);
    }
    function isBlacklisted(address account) public view returns(bool) {
        return _isBlacklisted[account];
    }
    function isExcludedFromMaxSellTransactionAmount(address account) public view returns(bool) {
        return _isExcludedFromMaxSellTransactionAmount[account];
    }

    function withdrawableDividendOf(address account) public view returns(uint256) {
    	return dividendTracker.withdrawableDividendOf(account);
  	}

	function dividendTokenBalanceOf(address account) public view returns (uint256) {
		return dividendTracker.balanceOf(account);
	}

    function getAccountDividendsInfo(address account)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
        return dividendTracker.getAccount(account);
    }

	function getAccountDividendsInfoAtIndex(uint256 index)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
    	return dividendTracker.getAccountAtIndex(index);
    }

	function processDividendTracker(uint256 gas) external {
		(uint256 iterations, uint256 claims, uint256 lastProcessedIndex) = dividendTracker.process(gas);
		emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, false, gas, tx.origin);
    }
    function claim() external {
		dividendTracker.processAccount(payable(msg.sender), false);
    }

    function getLastProcessedIndex() external view returns(uint256) {
    	return dividendTracker.getLastProcessedIndex();
    }

    function getNumberOfDividendTokenHolders() external view returns(uint256) {
        return dividendTracker.getNumberOfTokenHolders();
    }

    function getTradingIsEnabled() public view returns (bool) {
        return block.timestamp >= tradingEnabledTimestamp;
    }

    function setTradingEnabledTimestamp(uint256 timestamp) external onlyOwner {
        require(tradingEnabledTimestamp > block.timestamp, "SFZ: Changing the timestamp is not allowed if the listing has already started");
        tradingEnabledTimestamp = timestamp;
    }
    function setMaxSellTransactionAmount(uint256 amount) external onlyOwner {
        require(amount >= 1* 10 ** 11 && amount <= 1* 10 ** 13, "SFZ: Amount must be bewteen 0.01% and 1% of the total initial supply");
        maxSellTransactionAmount = amount *10**9;
        emit MaxSellTransactionAmountUpdated(amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0), "ERC20: Transfer from the zero address");
        require(to != address(0), "ERC20: Transfer to the zero address");
        require(amount >= 0, "ERC20: Transfer amount must be greater or equals to zero");
        require(!_isBlacklisted[to], "SFZ: Recipient is backlisted");
        require(!_isBlacklisted[from], "SFZ: Sender is backlisted");
        require(!paused(), "SFZ: The smart contract is paused");

        bool tradingIsEnabled = getTradingIsEnabled();
        // only whitelisted addresses can make transfers before the official PancakeSwap listing
        if(!tradingIsEnabled) {
            require(_canTransferBeforeTradingIsEnabled[from], "SFZ: This account cannot send tokens until trading is enabled");
        }
        bool isSellTransfer = automatedMarketMakerPairs[to];

        if( 
            !_isSwapping &&
        	tradingIsEnabled &&
            isSellTransfer && // sells only by detecting transfer to automated market maker pair
        	from != address(uniswapV2Router) && //router -> pair is removing liquidity which shouldn't have max
            !_isExcludedFromMaxSellTransactionAmount[to] &&
            !_isExcludedFromMaxSellTransactionAmount[from] //no max for those excluded from fees
        ) {
            require(amount <= maxSellTransactionAmount, "SFZ: Sell transfer amount exceeds the maxSellTransactionAmount.");
        }
		uint256 contractTokenBalance = balanceOf(address(this));
        
        bool canSwap = contractTokenBalance >= _swapTokensAtAmount;

        if(
            tradingIsEnabled && 
            canSwap &&
            !_isSwapping &&
            !automatedMarketMakerPairs[from] &&
            from != liquidityWallet &&
            to != liquidityWallet
        ) {
            _isSwapping = true;

            swapAndDistribute(balanceOf(address(this)));

            _isSwapping = false;
        }

        bool takeFee = tradingIsEnabled && !_isSwapping;

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if(_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        if(takeFee) {
            uint256 fees = amount.mul(totalFees).div(100);
        	amount = amount.sub(fees);

            super._transfer(from, address(this), fees);
        }

        super._transfer(from, to, amount);

        try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {}
        try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {}

        if(!_isSwapping) {
	    	uint256 gas = gasForProcessing;

	    	try dividendTracker.process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
	    		emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
	    	} 
	    	catch {

	    	}
        }
    }

     function tryToDistributeTokensManually() external payable authorized {        
        if(
            getTradingIsEnabled() && 
            !_isSwapping
        ) {
            _isSwapping = true;

            swapAndDistribute(balanceOf(address(this)));

            _isSwapping = false;
        }
    } 
    function swapAndDistribute(uint256 amount) private {

        uint256 liquidityTokensToNotSwap = amount.mul(liquidityFee).div(totalFees).div(2);


        uint256 initialBalance = address(this).balance;
        // swap tokens for BNB
        swapTokensForEth(amount.sub(liquidityTokensToNotSwap));

        // how much BNB did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);
        uint256 marketingAmount = newBalance.mul(marketingFee).div(85).mul(10);
        uint256 dividendAmount = newBalance.mul(BNBRewardsFee).div(85).mul(10);
        uint256 giftAmount = newBalance.mul(giftFee).div(85).mul(10);
        uint256 liquidityAmount = newBalance.sub(marketingAmount).sub(dividendAmount).sub(giftAmount);

        // add liquidity to Pancakeswap
        addLiquidity(liquidityTokensToNotSwap, liquidityAmount);
        sendHolderDividends(dividendAmount);
        sendMarketingDividends(marketingAmount);
        sendGiftDividends(giftAmount);
        emit SwapAndLiquify(amount.sub(liquidityTokensToNotSwap), newBalance, liquidityTokensToNotSwap);

    }

    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
        
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // add the liquidity
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            liquidityWallet,
            block.timestamp
        );
        
    }
    function sendHolderDividends(uint256 amount) private {

        (bool success,) = payable(address(dividendTracker)).call{value: amount}("");

        if(success) {
   	 		emit SendHolderDividends(amount);
        }
    }

    function sendMarketingDividends(uint256 amount) private {
        (bool success,) = payable(address(marketingWallet)).call{value: amount}("");

        if(success) {
   	 		emit SendMarketingDividends(amount);
        }
    }
    function sendGiftDividends(uint256 amount) private {
        (bool success,) = payable(address(giftWallet)).call{value: amount}("");

        if(success) {
   	 		emit SendGiftDividends(amount);
        }
    }

    // To add presale and locker's addresses
    function addAccountToTheseThatcanTransferBeforeTradingIsEnabled(address account) external onlyOwner {
        require(!_canTransferBeforeTradingIsEnabled[account],"SFZ: This account is already added");
        _canTransferBeforeTradingIsEnabled[account] = true;
    }

    function excludeFromDividends(address account) external authorized {
        dividendTracker.excludeFromDividends(account);
    }

    function includeInDividends(address account) external authorized {
        dividendTracker.includeInDividends(account,balanceOf(account));
    }

    function getStuckBNBs(address payable to) external onlyOwner {
        require(address(this).balance > 0, "SFZ: There are no BNBs in the contract");
        to.transfer(address(this).balance);
    }  

    function blackList(address _account ) public authorized {
        require(!_isBlacklisted[_account], "SFZ: This address is already blacklisted");
        require(_account != owner(), "SFZ: Blacklisting the owner is not allowed");
        require(_account != address(0), "SFZ: Blacklisting the 0 address is not allowed");
        require(_account != uniswapV2Pair, "SFZ: Blacklisting the pair address is not allowed");
        require(_account != address(this), "SFZ: Blacklisting the contract address is not allowed");

        _isBlacklisted[_account] = true;
        emit BlackList(_account,true);
    }
    
    function removeFromBlacklist(address _account) public authorized {
        require(_isBlacklisted[_account], "SFZ: This address already whitelisted");
        _isBlacklisted[_account] = false;
        emit BlackList(_account,false);
    }

    function getCirculatingSupply() external view returns (uint256) {
        return totalSupply().sub(balanceOf(DEAD));
    }

    function burn(uint256 amount) external returns (bool) {
        _transfer(_msgSender(), DEAD, amount);
        emit Burn(amount);
        return true;
    }

    function setSwapTokenAtAmount(uint256 amount) external onlyOwner {
        require(amount > 0 && amount < totalSupply() /10**9, "SFZ: Amount must be bewteen 0 and total supply");
        _swapTokensAtAmount = amount *10**9;

    }

    function setGasForWithdrawingDividendOfUser(uint16 newGas) external onlyOwner{
        dividendTracker.setGasForWithdrawingDividendOfUser(newGas);
    }

}

contract SFZDividendTracker is DividendPayingToken, Ownable {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using IterableMapping for IterableMapping.Map;

    IterableMapping.Map private tokenHoldersMap;
    uint256 public lastProcessedIndex;

    mapping (address => bool) private _excludedFromDividends;

    mapping (address => uint256) public lastClaimTimes;

    uint256 public claimWait;
    uint256 public immutable MINIMUM_TOKEN_BALANCE_FOR_DIVIDENDS; 

    event ExcludeFromDividends(address indexed account);
    event IncludeInDividends(address indexed account);
    event ClaimWaitUpdated(uint256 indexed newValue, uint256 indexed oldValue);
    event SetBalance(address payable account, uint256 newBalance);

    event Claim(address indexed account, uint256 amount, bool indexed automatic);

    constructor() DividendPayingToken("SFZ_Dividend_Tracker", "SFZ_Dividend_Tracker") {
    	claimWait = 43200; // 12h
        MINIMUM_TOKEN_BALANCE_FOR_DIVIDENDS = 2 * 10**8 * (10**9); //must hold 200 000 000 + tokens
    }

    function _transfer(address, address, uint256) pure internal override {
        require(false, "SFZ_Dividend_Tracker: No transfers allowed");
    }

    function withdrawDividend() pure public override {
        require(false, "SFZ_Dividend_Tracker: withdrawDividend disabled. Use the 'claim' function on the main SFZ contract.");
    }
    function isExcludedFromDividends(address account) external view returns(bool) {
        return _excludedFromDividends[account];
    }
    function excludeFromDividends(address account) external onlyOwner {
    	require(!_excludedFromDividends[account]);
    	_excludedFromDividends[account] = true;
    	_setBalance(account, 0);
    	tokenHoldersMap.remove(account);

    	emit ExcludeFromDividends(account);
    }

    function includeInDividends(address account, uint256 balance) external onlyOwner {
    	require(_excludedFromDividends[account]);
    	_excludedFromDividends[account] = false;
        if(balance >= MINIMUM_TOKEN_BALANCE_FOR_DIVIDENDS) {
            _setBalance(account, balance);
    		tokenHoldersMap.set(account, balance);
    	}
    	emit IncludeInDividends(account);
    }

    function updateClaimWait(uint256 newClaimWait) external onlyOwner {
        require(newClaimWait >= 3600 && newClaimWait <= 86400, "SFZ_Dividend_Tracker: claimWait must be updated to between 1 and 24 hours");
        require(newClaimWait != claimWait, "SFZ_Dividend_Tracker: Cannot update claimWait to same value");
        emit ClaimWaitUpdated(newClaimWait, claimWait);
        claimWait = newClaimWait;
    }

    function getLastProcessedIndex() external view returns(uint256) {
    	return lastProcessedIndex;
    }

    function getNumberOfTokenHolders() external view returns(uint256) {
        return tokenHoldersMap.keys.length;
    }



    function getAccount(address _account)
        public view returns (
            address account,
            int256 index,
            int256 iterationsUntilProcessed,
            uint256 withdrawableDividends,
            uint256 totalDividends,
            uint256 lastClaimTime,
            uint256 nextClaimTime,
            uint256 secondsUntilAutoClaimAvailable) {
        account = _account;

        index = tokenHoldersMap.getIndexOfKey(account);

        iterationsUntilProcessed = -1;
        if(index >= 0) {
            if(uint256(index) > lastProcessedIndex) {
                iterationsUntilProcessed = index.sub(int256(lastProcessedIndex));
            }
            else {
                uint256 processesUntilEndOfArray = tokenHoldersMap.keys.length > lastProcessedIndex ?
                                                        tokenHoldersMap.keys.length.sub(lastProcessedIndex) :
                                                        0;


                iterationsUntilProcessed = index.add(int256(processesUntilEndOfArray));
            }
        }


        withdrawableDividends = withdrawableDividendOf(account);
        totalDividends = accumulativeDividendOf(account);

        lastClaimTime = lastClaimTimes[account];

        nextClaimTime = lastClaimTime > 0 ?
                                    lastClaimTime.add(claimWait) :
                                    0;

        secondsUntilAutoClaimAvailable = nextClaimTime > block.timestamp ?
                                                    nextClaimTime.sub(block.timestamp) :
                                                    0;
    }

    function getAccountAtIndex(uint256 index)
        public view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
    	if(index >= tokenHoldersMap.size()) {
            return (0x0000000000000000000000000000000000000000, -1, -1, 0, 0, 0, 0, 0);
        }

        address account = tokenHoldersMap.getKeyAtIndex(index);

        return getAccount(account);
    }

    function canAutoClaim(uint256 lastClaimTime) private view returns (bool) {
    	if(lastClaimTime > block.timestamp)  {
    		return false;
    	}

    	return block.timestamp.sub(lastClaimTime) >= claimWait;
    }

    function setBalance(address payable account, uint256 newBalance) external onlyOwner {
    	if(_excludedFromDividends[account]) {
    		return;
    	}

    	if(newBalance >= MINIMUM_TOKEN_BALANCE_FOR_DIVIDENDS) {
            _setBalance(account, newBalance);
    		tokenHoldersMap.set(account, newBalance);
            emit SetBalance(account, newBalance);
    	}
    	else {
            _setBalance(account, 0);
    		tokenHoldersMap.remove(account);
            emit SetBalance(account, 0);
    	}

    	processAccount(account, true);
    }

    function process(uint256 gas) public returns (uint256, uint256, uint256) {
    	uint256 numberOfTokenHolders = tokenHoldersMap.keys.length;

    	if(numberOfTokenHolders == 0) {
    		return (0, 0, lastProcessedIndex);
    	}

    	uint256 _lastProcessedIndex = lastProcessedIndex;

    	uint256 gasUsed = 0;

    	uint256 gasLeft = gasleft();

    	uint256 iterations = 0;
    	uint256 claims = 0;

    	while(gasUsed < gas && iterations < numberOfTokenHolders) {
    		_lastProcessedIndex++;

    		if(_lastProcessedIndex >= tokenHoldersMap.keys.length) {
    			_lastProcessedIndex = 0;
    		}

    		address account = tokenHoldersMap.keys[_lastProcessedIndex];

    		if(canAutoClaim(lastClaimTimes[account])) {
    			if(processAccount(payable(account), true)) {
    				claims++;
    			}
    		}

    		iterations++;

    		uint256 newGasLeft = gasleft();

    		if(gasLeft > newGasLeft) {
    			gasUsed = gasUsed.add(gasLeft.sub(newGasLeft));
    		}

    		gasLeft = newGasLeft;
    	}

    	lastProcessedIndex = _lastProcessedIndex;

    	return (iterations, claims, lastProcessedIndex);
    }

    function processAccount(address payable account, bool automatic) public onlyOwner returns (bool) {
        uint256 amount = _withdrawDividendOfUser(account);

    	if(amount > 0) {
    		lastClaimTimes[account] = block.timestamp;
            emit Claim(account, amount, automatic);
    		return true;
    	}

    	return false;
    }

    function setGasForWithdrawingDividendOfUser(uint16 newGas) external onlyOwner{
        _setGasForWithdrawingDividendOfUser(newGas);
    }
}



