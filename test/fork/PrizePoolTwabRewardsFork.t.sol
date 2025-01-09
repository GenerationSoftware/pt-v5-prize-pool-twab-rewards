// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IMintableERC20 } from "./utils/IMintableERC20.sol";
import { TwabController } from "pt-v5-twab-controller/TwabController.sol";

import {
    IPrizePool,
    PrizePoolTwabRewards,
    TwabControllerZeroAddress,
    TokensReceivedLessThanExpected,
    ZeroTokensPerEpoch,
    ZeroEpochs,
    PayeeZeroAddress,
    GracePeriodActive,
    ExceedsMaxEpochs,
    RewardsAlreadyClaimed,
    PromotionInactive,
    OnlyPromotionCreator,
    InvalidPromotion,
    EpochNotOver,
    InvalidEpochId
} from "../../src/PrizePoolTwabRewards.sol";
import { Promotion } from "../../src/interfaces/IPrizePoolTwabRewards.sol";

contract PrizePoolTwabRewardsForkTest is Test {
    /* ============ Fork Vars ============ */

    uint256 public blockNumber = 111547798;

    address public twabControllerAddress = address(0x499a9F249ec4c8Ea190bebbFD96f9A83bf4F6E52);
    address public prizePoolAddress = address(0xF35fE10ffd0a9672d0095c435fd8767A7fe29B55);

    address public pusdce = address(0xE3B3a464ee575E8E25D2508918383b89c832f275);
    address public pweth = address(0x29Cb69D4780B53c1e5CD4D2B817142D2e9890715);

    address public pusdceHolder = address(0xbE4FeAE32210f682A41e1C41e3eaF4f8204cD29E);
    address public pwethHolder = address(0xbE4FeAE32210f682A41e1C41e3eaF4f8204cD29E);

    address public pusdceHolder2 = address(0xF80A7327CED2d6Aba7246E0DE1383DDb57fd4475);
    address public pwethHolder2 = address(0xF80A7327CED2d6Aba7246E0DE1383DDb57fd4475);

    address public opMinter = address(0x5C4e7Ba1E219E47948e6e3F55019A647bA501005);
    address public poolMinter = address(0x4200000000000000000000000000000000000010);

    IMintableERC20 public opToken = IMintableERC20(address(0x4200000000000000000000000000000000000042));
    IMintableERC20 public poolToken = IMintableERC20(address(0x395Ae52bB17aef68C2888d941736A71dC6d4e125));
    IMintableERC20 public usdceToken = IMintableERC20(address(0x7F5c764cBc14f9669B88837ca1490cCa17c31607));

    TokenTestCase[3] public tokenTestCases;

    /* ============ Variables ============ */

    PrizePoolTwabRewards public twabRewards;
    TwabController public twabController;
    IPrizePool public prizePool; 

    address public wallet1;
    address public wallet2;
    address public wallet3;

    address public customVaultAddress;

    uint48 public epochDuration = 1 days;
    uint8 public numberOfEpochs = 90; // about 3 months

    /* ============ Structs ============ */

    struct TokenTestCase {
        IMintableERC20 token;
        address minter;
        uint256 tokensPerEpochPusdce;
        uint256 tokensPerEpochPweth;
    }

    /* ============ Events ============ */

    event PromotionCreated(
        uint256 indexed promotionId,
        address indexed vault,
        IERC20 indexed token,
        uint48 startTimestamp,
        uint256 tokensPerEpoch,
        uint48 epochDuration,
        uint8 initialNumberOfEpochs
    );
    event PromotionEnded(uint256 indexed promotionId, address indexed recipient, uint256 amount, uint8 epochNumber);
    event PromotionDestroyed(uint256 indexed promotionId, address indexed recipient, uint256 amount);
    event PromotionExtended(uint256 indexed promotionId, uint256 numberOfEpochs);
    event RewardsClaimed(uint256 indexed promotionId, uint8[] epochIds, address indexed user, uint256 amount);

    event Transfer(address indexed from, address indexed to, uint256 amount);

    /* ============ Set Up ============ */

    function setUp() public {
        uint256 optimismFork = vm.createFork(vm.rpcUrl("optimism"), blockNumber);
        vm.selectFork(optimismFork);

        twabController = TwabController(twabControllerAddress);
        prizePool = IPrizePool(prizePoolAddress);
        twabRewards = new PrizePoolTwabRewards(twabController, prizePool);

        wallet1 = vm.addr(uint256(keccak256("wallet1")));
        wallet2 = vm.addr(uint256(keccak256("wallet2")));
        wallet3 = vm.addr(uint256(keccak256("wallet3")));

        customVaultAddress = vm.addr(uint256(keccak256("vault")));

        tokenTestCases[0] = TokenTestCase({
            token: opToken,
            minter: opMinter,
            tokensPerEpochPusdce: 21.52e18, // about 2% APR with $530k deposited & $1.36 OP price
            tokensPerEpochPweth: 3.42e18 // about 2% APR with $85k deposited & $1.36 OP price
        });

        tokenTestCases[1] = TokenTestCase({
            token: poolToken,
            minter: poolMinter,
            tokensPerEpochPusdce: 51.35e18, // about 2% APR with $530k deposited & $0.57 POOL price
            tokensPerEpochPweth: 8.16e18 // about 2% APR with $85k deposited & $0.57 POOL price
        });

        tokenTestCases[2] = TokenTestCase({
            token: usdceToken,
            minter: poolMinter,
            tokensPerEpochPusdce: 25e6,
            tokensPerEpochPweth: 4e6
        });
    }

    /* ============ Test OP rewards ============ */

    function testRewards() external {
        // Ensure vault token holders have a balance above zero
        assertGt(twabController.balanceOf(pusdce, pusdceHolder), 0);
        assertGt(twabController.balanceOf(pweth, pwethHolder), 0);
        assertGt(twabController.balanceOf(pusdce, pusdceHolder2), 0);
        assertGt(twabController.balanceOf(pweth, pwethHolder2), 0);

        // Ensure wallet with no vault tokens has a balance of zero
        assertEq(twabController.balanceOf(pusdce, wallet1), 0);
        assertEq(twabController.balanceOf(pweth, wallet1), 0);

        // Test promotion for each test token
        for (uint256 i = 0; i < 3; i++) {
            // Initialized promotion vars

            /**
             * NOTE: promotion start times MUST be aligned with the twab period and offset.
             */

            uint48 startTimestamp = uint48(
                twabController.PERIOD_OFFSET() +
                    twabController.PERIOD_LENGTH() *
                    ((block.timestamp - twabController.PERIOD_OFFSET()) / twabController.PERIOD_LENGTH() + 1)
            );

            {
                address rewardTokenMinter = tokenTestCases[i].minter;

                // Mint tokens to creator address
                uint256 totalAvailableRewards = (tokenTestCases[i].tokensPerEpochPusdce +
                    tokenTestCases[i].tokensPerEpochPweth) * numberOfEpochs;
                vm.startPrank(rewardTokenMinter);
                tokenTestCases[i].token.mint(address(this), totalAvailableRewards);
                vm.stopPrank();

                // Approve tokens
                tokenTestCases[i].token.approve(address(twabRewards), totalAvailableRewards);
            }

            // Setup new OP token promotions on pUSDC.e vault and pweth vault
            vm.expectEmit();
            emit PromotionCreated(
                1 + 2 * i,
                pusdce,
                tokenTestCases[i].token,
                startTimestamp,
                tokenTestCases[i].tokensPerEpochPusdce,
                epochDuration,
                numberOfEpochs
            );
            uint256 pusdcePromotionId = twabRewards.createPromotion(
                tokenTestCases[i].token,
                startTimestamp,
                tokenTestCases[i].tokensPerEpochPusdce,
                epochDuration,
                numberOfEpochs
            );
            assertEq(pusdcePromotionId, 1 + 2 * i);

            vm.expectEmit();
            emit PromotionCreated(
                2 + 2 * i,
                pweth,
                tokenTestCases[i].token,
                startTimestamp,
                tokenTestCases[i].tokensPerEpochPweth,
                epochDuration,
                numberOfEpochs
            );
            uint256 pwethPromotionId = twabRewards.createPromotion(
                tokenTestCases[i].token,
                startTimestamp,
                tokenTestCases[i].tokensPerEpochPweth,
                epochDuration,
                numberOfEpochs
            );
            assertEq(pwethPromotionId, 2 + 2 * i);

            {
                // Verify promotion information
                Promotion memory pusdcePromotion = twabRewards.getPromotion(pusdcePromotionId);
                Promotion memory pwethPromotion = twabRewards.getPromotion(pwethPromotionId);

                assertEq(pusdcePromotion.creator, address(this));
                assertEq(pusdcePromotion.startTimestamp, startTimestamp);
                assertEq(pusdcePromotion.numberOfEpochs, numberOfEpochs);
                assertEq(pusdcePromotion.epochDuration, epochDuration);
                assertEq(pusdcePromotion.createdAt, uint48(block.timestamp));
                assertEq(address(pusdcePromotion.token), address(tokenTestCases[i].token));
                assertEq(pusdcePromotion.tokensPerEpoch, tokenTestCases[i].tokensPerEpochPusdce);
                assertEq(pusdcePromotion.rewardsUnclaimed, tokenTestCases[i].tokensPerEpochPusdce * numberOfEpochs);

                assertEq(pwethPromotion.creator, address(this));
                assertEq(pwethPromotion.startTimestamp, startTimestamp);
                assertEq(pwethPromotion.numberOfEpochs, numberOfEpochs);
                assertEq(pwethPromotion.epochDuration, epochDuration);
                assertEq(pwethPromotion.createdAt, uint48(block.timestamp));
                assertEq(address(pwethPromotion.token), address(tokenTestCases[i].token));
                assertEq(pwethPromotion.tokensPerEpoch, tokenTestCases[i].tokensPerEpochPweth);
                assertEq(pwethPromotion.rewardsUnclaimed, tokenTestCases[i].tokensPerEpochPweth * numberOfEpochs);
            }

            {
                // Test current epoch ID
                assertEq(twabRewards.getCurrentEpochId(pusdcePromotionId), 0);
                assertEq(twabRewards.getCurrentEpochId(pwethPromotionId), 0);

                // Test remaining rewards
                assertEq(
                    twabRewards.getRemainingRewards(pusdcePromotionId),
                    tokenTestCases[i].tokensPerEpochPusdce * numberOfEpochs
                );
                assertEq(
                    twabRewards.getRemainingRewards(pwethPromotionId),
                    tokenTestCases[i].tokensPerEpochPweth * numberOfEpochs
                );

                // Test getRewardsAmount
                uint8[] memory zeroEpochArray = new uint8[](1);
                zeroEpochArray[0] = 0;
                vm.expectRevert(abi.encodeWithSelector(EpochNotOver.selector, startTimestamp + epochDuration));
                twabRewards.getRewardsAmount(pusdceHolder, pusdce, pusdcePromotionId, zeroEpochArray);
                vm.expectRevert(abi.encodeWithSelector(EpochNotOver.selector, startTimestamp + epochDuration));
                twabRewards.getRewardsAmount(pwethHolder, pweth, pwethPromotionId, zeroEpochArray);
            }

            {
                // Warp to halfway through first epoch
                vm.warp(startTimestamp);

                // Ensure claims can't occur yet
                uint8[] memory zeroEpochArray = new uint8[](1);
                zeroEpochArray[0] = 0;
                vm.expectRevert(abi.encodeWithSelector(EpochNotOver.selector, startTimestamp + epochDuration));
                twabRewards.claimRewards(pusdceHolder, pusdce, pusdcePromotionId, zeroEpochArray);
                vm.expectRevert(abi.encodeWithSelector(EpochNotOver.selector, startTimestamp + epochDuration));
                twabRewards.claimRewards(pwethHolder, pweth, pwethPromotionId, zeroEpochArray);
            }

            {
                // Warp to exact end of first epoch
                vm.warp(startTimestamp + epochDuration);

                // Transfer half of holder's pusdce balance away
                vm.startPrank(pusdce);
                twabController.transfer(
                    pusdceHolder,
                    wallet2,
                    uint96(twabController.balanceOf(pusdce, pusdceHolder) / 2)
                );
                vm.stopPrank();
            }

            // Record any expected reward balances for pusdce holder
            uint256 pusdceHolderExpectedRewards = 0;

            {
                // Warp to a bit after the first epoch
                vm.warp(startTimestamp + epochDuration + 1 days / 24);

                // Ensure there are no rewards available to a wallet without a balance
                uint8[] memory zeroEpochArray = new uint8[](1);
                zeroEpochArray[0] = 0;
                assertEq(twabRewards.getRewardsAmount(wallet1, pusdce, pusdcePromotionId, zeroEpochArray)[0], 0);

                {
                    // Check that the balance of rewards for the pUSDC.e vault token holders is proportional to their relative TWABs
                    uint256[] memory pusdceHolderRewards = twabRewards.getRewardsAmount(
                        pusdce,
                        pusdceHolder,
                        pusdcePromotionId,
                        zeroEpochArray
                    );
                    uint256[] memory pusdceHolder2Rewards = twabRewards.getRewardsAmount(
                        pusdce,
                        pusdceHolder2,
                        pusdcePromotionId,
                        zeroEpochArray
                    );

                    // Record expected reward amount:
                    pusdceHolderExpectedRewards += pusdceHolderRewards[0];

                    uint256 pusdceHolderTwab = twabController.getTwabBetween(
                        pusdce,
                        pusdceHolder,
                        startTimestamp,
                        startTimestamp + epochDuration
                    );
                    uint256 pusdceHolder2Twab = twabController.getTwabBetween(
                        pusdce,
                        pusdceHolder2,
                        startTimestamp,
                        startTimestamp + epochDuration
                    );

                    // Multiply by factor of 1e18 and check approximate proportions (checks similarity to 6 decimal points [18-12 = 6])
                    assertApproxEqAbs(
                        (1e18 * pusdceHolderRewards[0]) / pusdceHolderTwab,
                        (1e18 * pusdceHolder2Rewards[0]) / pusdceHolder2Twab,
                        1e12
                    );
                }

                // --- Do the same for pWETH ---

                {
                    // Check that the balance of rewards for the pWETH vault token holders is proportional to their relative TWABs
                    uint256[] memory pwethHolderRewards = twabRewards.getRewardsAmount(
                        pweth,
                        pwethHolder,
                        pwethPromotionId,
                        zeroEpochArray
                    );
                    uint256[] memory pwethHolder2Rewards = twabRewards.getRewardsAmount(
                        pweth,
                        pwethHolder2,
                        pwethPromotionId,
                        zeroEpochArray
                    );

                    uint256 pwethHolderTwab = twabController.getTwabBetween(
                        pweth,
                        pwethHolder,
                        startTimestamp,
                        startTimestamp + epochDuration
                    );
                    uint256 pwethHolder2Twab = twabController.getTwabBetween(
                        pweth,
                        pwethHolder2,
                        startTimestamp,
                        startTimestamp + epochDuration
                    );

                    // Multiply by factor of 1e18 and check approximate proportions (checks similarity to 6 decimal points [18-12 = 6])
                    assertApproxEqAbs(
                        (1e18 * pwethHolderRewards[0]) / pwethHolderTwab,
                        (1e18 * pwethHolder2Rewards[0]) / pwethHolder2Twab,
                        1e12
                    );
                }
            }

            {
                // Warp to end of second epoch
                vm.warp(startTimestamp + epochDuration * 2);

                uint8[] memory epochIds = new uint8[](2);
                epochIds[0] = 0;
                epochIds[1] = 1;

                {
                    // Get pUSDC.e reward amounts
                    uint256[] memory pusdceHolderRewards = twabRewards.getRewardsAmount(
                        pusdce,
                        pusdceHolder,
                        pusdcePromotionId,
                        epochIds
                    );
                    uint256[] memory pusdceHolder2Rewards = twabRewards.getRewardsAmount(
                        pusdce,
                        pusdceHolder2,
                        pusdcePromotionId,
                        epochIds
                    );

                    // Check that the pusdceHolder rewards haven't changed for the first epoch
                    assertEq(pusdceHolderRewards[0], pusdceHolderExpectedRewards, "first epoch rewards don't change");

                    // Add epoch 2 rewards to expected rewards
                    pusdceHolderExpectedRewards += pusdceHolderRewards[1];

                    // Check that the pusdceHolder rewards have gone down from the first epoch
                    // We halved their balance, but they still have a delegations, so we need to calculate the fractional reduction of rewards based off their new delegate balance over their old delegate balance.
                    uint256 expectedSecondEpochRewards = (pusdceHolderRewards[0] *
                        twabController.delegateBalanceOf(pusdce, pusdceHolder)) /
                        (twabController.delegateBalanceOf(pusdce, pusdceHolder) +
                            twabController.balanceOf(pusdce, pusdceHolder));
                    assertApproxEqAbs(
                        pusdceHolderRewards[1],
                        expectedSecondEpochRewards,
                        10 ** (tokenTestCases[i].token.decimals() - 5),
                        "second epoch rewards proportional to new delegate balance"
                    );

                    // Check that the pusdceHolder2 rewards have not changed since the first epoch
                    assertEq(pusdceHolder2Rewards[0], pusdceHolder2Rewards[1], "epoch rewards same for second holder");
                }

                {
                    // Get pWETH reward amounts
                    uint256[] memory pwethHolderRewards = twabRewards.getRewardsAmount(
                        pweth,
                        pwethHolder,
                        pwethPromotionId,
                        epochIds
                    );
                    uint256[] memory pwethHolder2Rewards = twabRewards.getRewardsAmount(
                        pweth,
                        pwethHolder2,
                        pwethPromotionId,
                        epochIds
                    );

                    // Check that the pwethHolder rewards have not changed since the first epoch
                    assertEq(pwethHolderRewards[0], pwethHolderRewards[1]);

                    // Check that the pwethHolder2 rewards have not changed since the first epoch
                    assertEq(pwethHolder2Rewards[0], pwethHolder2Rewards[1]);
                }
            }

            {
                // Check that user no longer receives rewards if they delegate their balance away
                vm.warp(startTimestamp + epochDuration * 2);
                vm.startPrank(pusdceHolder2);
                twabController.delegate(pusdce, wallet2);
                vm.stopPrank();

                vm.warp(startTimestamp + epochDuration * 3);
                uint8[] memory epochIds = new uint8[](3);
                epochIds[0] = 0;
                epochIds[1] = 1;
                epochIds[2] = 2;

                uint256[] memory rewards = twabRewards.getRewardsAmount(pusdceHolder2, pusdce, pusdcePromotionId, epochIds);
                assertLt(rewards[2], rewards[1]);
                assertEq(rewards[2], 0);

                // delegate back to self
                vm.startPrank(pusdceHolder2);
                twabController.delegate(pusdce, pusdceHolder2);
                vm.stopPrank();
            }

            {
                // Check if users can multicall claim for both vaults
                uint8[] memory epochIds = new uint8[](3);
                epochIds[0] = 0;
                epochIds[1] = 1;
                epochIds[2] = 2;

                // Make sure pusdceHolder and pwethHolder are the same address for this test
                assertEq(
                    pusdceHolder,
                    pwethHolder,
                    "This test requires pusdce and pweth holder #1 to be the same address."
                );

                uint256[] memory pusdceRewards = twabRewards.getRewardsAmount(
                    pusdce,
                    pusdceHolder,
                    pusdcePromotionId,
                    epochIds
                );
                uint256[] memory pwethRewards = twabRewards.getRewardsAmount(pweth, pwethHolder, pwethPromotionId, epochIds);

                uint256 totalExpectedRewards = pusdceRewards[0] +
                    pusdceRewards[1] +
                    pusdceRewards[2] +
                    pwethRewards[0] +
                    pwethRewards[1] +
                    pwethRewards[2];
                assertGt(totalExpectedRewards, 0);

                bytes[] memory multicallData = new bytes[](2);
                multicallData[0] = abi.encodeWithSelector(
                    twabRewards.claimRewards.selector,
                    pusdceHolder,
                    pusdcePromotionId,
                    epochIds
                );
                multicallData[1] = abi.encodeWithSelector(
                    twabRewards.claimRewards.selector,
                    pwethHolder,
                    pwethPromotionId,
                    epochIds
                );

                vm.expectEmit();
                emit Transfer(
                    address(twabRewards),
                    pusdceHolder,
                    pusdceRewards[0] + pusdceRewards[1] + pusdceRewards[2]
                );
                vm.expectEmit();
                emit RewardsClaimed(
                    pusdcePromotionId,
                    epochIds,
                    pusdceHolder,
                    pusdceRewards[0] + pusdceRewards[1] + pusdceRewards[2]
                );
                emit Transfer(address(twabRewards), pwethHolder, pwethRewards[0] + pwethRewards[1] + pwethRewards[2]);
                vm.expectEmit();
                emit RewardsClaimed(
                    pwethPromotionId,
                    epochIds,
                    pwethHolder,
                    pwethRewards[0] + pwethRewards[1] + pwethRewards[2]
                );
                twabRewards.multicall(multicallData);
            }

            {
                // Check if users can still claim past the 60 day grace period as long as the promotion hasn't been destroyed
                vm.warp(startTimestamp + epochDuration * numberOfEpochs + 61 days);
                uint8[] memory epochIds = new uint8[](numberOfEpochs);
                for (uint8 j = 0; j < numberOfEpochs; j++) {
                    epochIds[j] = j;
                }

                // Make sure pusdceHolder2 and pwethHolder2 are the same address for this test
                assertEq(
                    pusdceHolder2,
                    pwethHolder2,
                    "This test requires pusdce and pweth holder #2 to be the same address."
                );

                uint256[] memory pusdceRewards = twabRewards.getRewardsAmount(
                    pusdce,
                    pusdceHolder2,
                    pusdcePromotionId,
                    epochIds
                );
                uint256[] memory pwethRewards = twabRewards.getRewardsAmount(pweth, pwethHolder2, pwethPromotionId, epochIds);

                uint256 totalPusdceRewards = 0;
                uint256 totalPwethRewards = 0;
                for (uint8 j = 0; j < numberOfEpochs; j++) {
                    totalPusdceRewards += pusdceRewards[j];
                    totalPwethRewards += pwethRewards[j];
                }

                bytes[] memory multicallData = new bytes[](2);
                multicallData[0] = abi.encodeWithSelector(
                    twabRewards.claimRewards.selector,
                    pusdceHolder2,
                    pusdcePromotionId,
                    epochIds
                );
                multicallData[1] = abi.encodeWithSelector(
                    twabRewards.claimRewards.selector,
                    pwethHolder2,
                    pwethPromotionId,
                    epochIds
                );

                assertGt(totalPusdceRewards, 0);
                assertGt(totalPwethRewards, 0);

                vm.expectEmit();
                emit Transfer(address(twabRewards), pusdceHolder2, totalPusdceRewards);
                vm.expectEmit();
                emit RewardsClaimed(pusdcePromotionId, epochIds, pusdceHolder2, totalPusdceRewards);
                emit Transfer(address(twabRewards), pwethHolder2, totalPwethRewards);
                vm.expectEmit();
                emit RewardsClaimed(pwethPromotionId, epochIds, pwethHolder2, totalPwethRewards);
                twabRewards.multicall(multicallData);
            }

            {
                // Check that promotion owners can reclaim unclaimed rewards
                Promotion memory pusdcePromotion = twabRewards.getPromotion(pusdcePromotionId);
                uint256 rewardsUnclaimed = pusdcePromotion.rewardsUnclaimed;

                uint256 balanceBefore = tokenTestCases[i].token.balanceOf(address(this));
                vm.expectEmit();
                emit PromotionDestroyed(pusdcePromotionId, address(this), rewardsUnclaimed);
                twabRewards.destroyPromotion(pusdcePromotionId, address(this));
                uint256 balanceAfter = tokenTestCases[i].token.balanceOf(address(this));
                assertEq(balanceAfter - balanceBefore, rewardsUnclaimed);
            }

            {
                // Check that destroyed promotion rewards can no longer be claimed
                uint8[] memory epochIds = new uint8[](3);
                epochIds[0] = 3;
                epochIds[1] = 4;
                epochIds[2] = 5;

                vm.expectRevert(abi.encodeWithSelector(InvalidPromotion.selector, pusdcePromotionId));
                twabRewards.claimRewards(pusdceHolder, pusdce, pusdcePromotionId, epochIds);
            }
        }
    }
}
