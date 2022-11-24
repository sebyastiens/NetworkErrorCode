pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "@studydefi/money-legos/dydx/contracts/DydxFlashloanBase.sol";
import "@studydefi/money-legos/dydx/contracts/ICallee.sol";
import { KyberNetworkProxy as IKyberNetworkProxy } from '@studydefi/money-legos/kyber/contracts/KyberNetworkProxy.sol';

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./IWeth.sol";
import "./IUniswapV2Router02.sol";



contract Flashloan is ICallee, DydxFlashloanBase { //DydxFlashloaner
    enum Direction { KyberToUniswap, UniswapToKyber }
    struct ArbInfo { // before was MyCustomData
        Direction direction; //before was address token
        uint repayAmount;
    }

    event NewArbitrage (
        Direction direction,
        uint profit,
        uint date
        );

    IKyberNetworkProxy kyber;
    IUniswapV2Router02 uniswap;
    IWeth weth;
    IERC20 dai;
    address beneficiary;
    address constant KYBER_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; // constant pour intéragir avec eth sur Kyber

    constructor (
        address kyberAddress,
        address uniswapAddress,
        address wethAddress,
        address daiAddress,
        address beneficiaryAddress)
        public {
            kyber = IKyberNetworkProxy (kyberAddress);
            uniswap = IUniswapV2Router02(uniswapAddress);
            weth = IWeth(wethAddress);
            dai = IERC20(daiAddress);
            beneficiary = beneficiaryAddress;
    }

    // This is the function that will be called postLoan
    // i.e. Encode the logic to handle your flashloaned funds here
    function callFunction ( 
        address sender,
        Account.Info memory account,
        bytes memory data // this will be our ArbInfo struct. it's more flexible to pass bytes than a struct. Cause the money-legos creators don't know about what we'll pass here.
    ) public override { //added override
        ArbInfo memory arbInfo = abi.decode(data, (ArbInfo)); // was called mcd instead of arbInfo
        uint256 balanceDai = dai.balanceOf(address(this));// we check to ensure we have received enough tokens from dydx
        if (arbInfo.direction == Direction.KyberToUniswap)  {
            //Buy ETH on Kyber 
              dai.approve(address(kyber), balanceDai);  //approve the dai to be spent by Kyber
              (uint expectedRate,) = kyber.getExpectedRate( //this takes 3 arguments but we only want to expected rate
                    dai, // pointer to the token that we provide in input
                    IERC20(KYBER_ETH_ADDRESS), // pointer to the output token which is ETH. And this is how Kyber referencs ETH
                    balanceDai //amount of dai we want to trade
              );
              kyber.swapTokenToEther(dai, balanceDai, expectedRate); // after we can finally trade so we use the method swapTokenToEth

            // sell ETH on Uniswap
                // sur Uniswap c'est plus complexe car on peur faire une série d'opérations genre de token A à B puis B à C etc... => on spécifie un path plutôt que juste le token innput et output
                address [] memory path = new address [](2); // length 2 car ici on a que 2 tokens
                path[0] = address(weth);
                path[1] = address(dai);
                uint [] memory minOuts = uniswap.getAmountsOut(address(this).balance, path); // It's a unit array because if we have a longer paths, we'll have amount from path[0] to path[1], then path[1] to path[2] etc..
                uniswap.swapExactETHForTokens { value : address(this).balance}( // that's the uniswap function to do the trade. We use .value to send this value (=msg.value) to the function. //Before .value(address(this).balance)
                    minOuts[1], // that's the minimum price that we want in dai
                    path,
                    address(this), // c'est cette addresse qui va recevoir les dai
                    block.timestamp // avant now
                ); 
        }
        else if (arbInfo.direction == Direction.UniswapToKyber){ // il a mit else lui
            //Buy ETH on Uniswap
              dai.approve(address(uniswap), balanceDai);  //approve the dai to be spent by Uniswap
              address [] memory path = new address [](2); // length 2 car ici on a que 2 tokens
              path[0] = address(dai);
              path[1] = address(weth);
              uint [] memory minOuts = uniswap.getAmountsOut(balanceDai, path); 
              uniswap.swapExactTokensForETH( // that's the uniswap function to do the trade.
                    balanceDai,
                    minOuts[1], // that's the minimum price that we want in dai
                    path,
                    address(this), // c'est cette addresse qui va recevoir les weth
                    block.timestamp // avant now
                ); 
            // sell ETH on Kyber
              (uint expectedRate,) = kyber.getExpectedRate(
                    IERC20(KYBER_ETH_ADDRESS), // pointer to the input token
                    dai, // pointer to the output token which is dai
                    address(this).balance //amount of ETH we want to trade
              );
              kyber.swapEtherToToken { value : address(this).balance }( // Before : .value(address(this).balance)
                dai, 
                expectedRate
                );
        }
        require( // to ensure that after the whole call we have enough funds to repay
            dai.balanceOf(address(this)) >= arbInfo.repayAmount,
            "Not enough funds to repay Dydx loan!"
        );

        uint profit = dai.balanceOf(address(this)) - arbInfo.repayAmount;
        dai.transfer(beneficiary, profit);
        emit NewArbitrage(arbInfo.direction, profit, block.timestamp); // avant now
        // uint256 balOfLoanedToken = IERC20(mcd.token).balanceOf(address(this));

        // //Note that you can ignore the line below
        // //if your dydx account (this contract in this case)
        // //has deposted at least 2 Wei of assets into the account
        // // to balance out the collaterization ratio
        // require(
        //     balOfLoanedToken >= mcd.repayAmount,
        //     "Not enough funds to repay dydx loan!"
        // );

        // //TODO : encode your logic here
        // // E.g arbitrage, liquidate accounts, etc.
        // revert("Hello, you haven't encoded your logic");
    }

    function initiateFlashloan(
      address _solo,  //address of dydx
      address _token, //address of token to borrow
      uint256 _amount,
      Direction _direction) 
        external 
    {
        ISoloMargin solo = ISoloMargin(_solo);

        // Get marketId from token address
        uint256 marketId = _getMarketIdFromTokenAddress(_solo, _token);

        // Calculate repay amount (_amount + (2 wei))
        // Approve transfer from
        uint256 repayAmount = _getRepaymentAmountInternal(_amount);
        IERC20(_token).approve(_solo, repayAmount);

        // 1. Withdraw $
        // 2. Call callFunction(...)
        // 3. Deposit back $
        Actions.ActionArgs[] memory operations = new Actions.ActionArgs[](3);

        operations[0] = _getWithdrawAction(marketId, _amount); // when we borrow the token from dydx
        operations[1] = _getCallAction( // that's when we call to any arbitrary sc execution -> our arbitrage logic
            // Encode MyCustomData for callFunction
            abi.encode(ArbInfo({direction: _direction, repayAmount: repayAmount}))
        );
        operations[2] = _getDepositAction(marketId, repayAmount); // when we pay back the flashloan to dydx

        Account.Info[] memory accountInfos = new Account.Info[](1);
        accountInfos[0] = _getAccountInfo();

        solo.operate(accountInfos, operations);
    }

    receive() external payable {} // when we send ETH to a contract without calling a function, 
                                  //it means we'll call the fallback function (the receive function in the latest version) 
                                  //and if this function doesn't exist the ETH transfer will fail.
 
                
    
}