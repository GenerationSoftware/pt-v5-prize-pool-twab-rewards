// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "openzeppelin-contracts/mocks/ERC20Mock.sol";
import { FeeERC20 } from "./mocks/FeeERC20.sol";
import { TwabController } from "pt-v5-twab-controller/TwabController.sol";

import {
    TwabRewards,
    TwabControllerZeroAddress,
    TokensReceivedLessThanExpected,
    ZeroTokensPerEpoch,
    ZeroEpochDuration,
    ZeroEpochs,
    PayeeZeroAddress,
    GracePeriodActive,
    ExceedsMaxEpochs,
    RewardsAlreadyClaimed,
    PromotionInactive,
    OnlyPromotionCreator,
    InvalidPromotion,
    EpochNotOver,
    InvalidEpochId,
    EpochDurationNotMultipleOfTwabPeriod,
    StartTimeNotAlignedWithTwabPeriod
} from "../src/TwabRewards.sol";
import { Promotion } from "../src/interfaces/ITwabRewards.sol";

contract TwabRewardsTest is Test {
    TwabRewards public twabRewards;
    TwabController public twabController;
    ERC20Mock public mockToken;

    address wallet1;
    address wallet2;
    address wallet3;

    address vaultAddress;

    uint32 twabPeriodLength = 1 hours;
    uint32 twabPeriodOffset = 0;

    uint64 promotionStartTime = 1 days;
    uint64 promotionCreatedAt = 0;

    uint256 tokensPerEpoch = 10000e18;
    uint48 epochDuration = 604800; // 1 week in seconds
    uint8 numberOfEpochs = 12;

    uint256 promotionId;
    Promotion public promotion;

    /* ============ Events ============ */

    event PromotionCreated(
        uint256 indexed promotionId,
        address indexed vault,
        IERC20 indexed token,
        uint64 startTimestamp,
        uint256 tokensPerEpoch,
        uint48 epochDuration,
        uint8 initialNumberOfEpochs
    );
    event PromotionEnded(uint256 indexed promotionId, address indexed recipient, uint256 amount, uint8 epochNumber);
    event PromotionDestroyed(uint256 indexed promotionId, address indexed recipient, uint256 amount);
    event PromotionExtended(uint256 indexed promotionId, uint256 numberOfEpochs);
    event RewardsClaimed(uint256 indexed promotionId, uint8[] epochIds, address indexed user, uint256 amount);

    /* ============ Set Up ============ */

    function setUp() public {
        twabController = new TwabController(twabPeriodLength, twabPeriodOffset);
        mockToken = new ERC20Mock();
        twabRewards = new TwabRewards(twabController);

        wallet1 = vm.addr(uint256(keccak256("wallet1")));
        wallet2 = vm.addr(uint256(keccak256("wallet2")));
        wallet3 = vm.addr(uint256(keccak256("wallet3")));

        vaultAddress = vm.addr(uint256(keccak256("vault")));

        promotionId = createPromotion();
        promotion = twabRewards.getPromotion(promotionId);
        promotionCreatedAt = uint48(block.timestamp);
    }

    /* ============ constructor ============ */

    function testConstructor_SetsTwabController() external {
        assertEq(address(twabRewards.twabController()), address(twabController));
    }

    function testConstructor_TwabControllerZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(TwabControllerZeroAddress.selector));
        new TwabRewards(TwabController(address(0)));
    }

    /* ============ createPromotion ============ */

    function testCreatePromotion() external {
        vm.startPrank(wallet1);

        uint256 amount = tokensPerEpoch * numberOfEpochs;
        mockToken.mint(wallet1, amount);
        mockToken.approve(address(twabRewards), amount);

        uint64 _startTimestamp = 1 days;
        uint256 _promotionId = 2;
        vm.expectEmit();
        emit PromotionCreated(
            _promotionId,
            vaultAddress,
            IERC20(mockToken),
            _startTimestamp,
            tokensPerEpoch,
            epochDuration,
            numberOfEpochs
        );
        twabRewards.createPromotion(
            vaultAddress,
            mockToken,
            _startTimestamp,
            tokensPerEpoch,
            epochDuration,
            numberOfEpochs
        );
        vm.stopPrank();
    }

    function testCreatePromotion_FeeTokenFails() external {
        FeeERC20 feeToken = new FeeERC20();
        uint256 amount = tokensPerEpoch * numberOfEpochs;
        feeToken.mint(address(this), amount);
        feeToken.approve(address(twabRewards), amount);

        vm.expectRevert(abi.encodeWithSelector(TokensReceivedLessThanExpected.selector, amount - amount / 100, amount));
        twabRewards.createPromotion(
            vaultAddress,
            feeToken,
            promotionStartTime,
            tokensPerEpoch,
            epochDuration,
            numberOfEpochs
        );
    }

    function testCreatePromotion_ZeroTokensPerEpoch() external {
        uint256 _tokensPerEpoch = 0;
        uint256 amount = _tokensPerEpoch * numberOfEpochs;
        mockToken.mint(address(this), amount);
        mockToken.approve(address(twabRewards), amount);

        vm.expectRevert(abi.encodeWithSelector(ZeroTokensPerEpoch.selector));
        twabRewards.createPromotion(
            vaultAddress,
            mockToken,
            promotionStartTime,
            _tokensPerEpoch,
            epochDuration,
            numberOfEpochs
        );
    }

    function testCreatePromotion_ZeroEpochDuration() external {
        uint256 amount = tokensPerEpoch * numberOfEpochs;
        mockToken.mint(address(this), amount);
        mockToken.approve(address(twabRewards), amount);

        vm.expectRevert(abi.encodeWithSelector(ZeroEpochDuration.selector));
        twabRewards.createPromotion(
            vaultAddress,
            mockToken,
            promotionStartTime,
            tokensPerEpoch,
            0, // epoch duration zero
            numberOfEpochs
        );
    }

    function testCreatePromotion_ZeroEpochs() external {
        vm.expectRevert(abi.encodeWithSelector(ZeroEpochs.selector));
        twabRewards.createPromotion(
            vaultAddress,
            mockToken,
            promotionStartTime,
            tokensPerEpoch,
            epochDuration,
            0 // 0 number of epochs
        );
    }

    function testFailCreatePromotion_TooManyEpochs() external {
        twabRewards.createPromotion(
            vaultAddress,
            mockToken,
            promotionStartTime,
            tokensPerEpoch,
            epochDuration,
            uint8(uint256(256)) // over max uint8
        );
    }

    function testCreatePromotion_EpochDurationNotMultipleOfTwabPeriod() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                EpochDurationNotMultipleOfTwabPeriod.selector,
                twabPeriodLength / 2,
                twabPeriodLength
            )
        );
        twabRewards.createPromotion(
            vaultAddress,
            mockToken,
            promotionStartTime,
            tokensPerEpoch,
            twabPeriodLength / 2,
            numberOfEpochs
        );
    }

    function testCreatePromotion_StartTimeNotAlignedWithTwabPeriod() external {
        vm.expectRevert(abi.encodeWithSelector(StartTimeNotAlignedWithTwabPeriod.selector, 13));
        twabRewards.createPromotion(
            vaultAddress,
            mockToken,
            promotionStartTime + 13,
            tokensPerEpoch,
            epochDuration,
            numberOfEpochs
        );
    }

    /* ============ endPromotion ============ */

    function testEndPromotion_TransfersCorrectAmount() external {
        for (uint8 epochToEndOn = 0; epochToEndOn < numberOfEpochs; epochToEndOn++) {
            uint256 _promotionId = createPromotion();
            vm.warp(epochToEndOn * epochDuration + promotionStartTime);
            uint256 _refundAmount = tokensPerEpoch * (numberOfEpochs - epochToEndOn);

            uint256 balanceBefore = mockToken.balanceOf(address(this));

            vm.expectEmit();
            emit PromotionEnded(_promotionId, address(this), _refundAmount, epochToEndOn);
            twabRewards.endPromotion(_promotionId, address(this));

            uint256 balanceAfter = mockToken.balanceOf(address(this));
            assertEq(balanceAfter - balanceBefore, _refundAmount);

            uint8 latestEpochId = twabRewards.getPromotion(_promotionId).numberOfEpochs;
            assertEq(latestEpochId, twabRewards.getCurrentEpochId(_promotionId));
        }
    }

    function testEndPromotion_EndBeforeStarted() external {
        uint256 amount = tokensPerEpoch * numberOfEpochs;
        mockToken.mint(address(this), amount);
        mockToken.approve(address(twabRewards), amount);

        uint64 _startTimestamp = 1 days;
        uint256 _promotionId = twabRewards.createPromotion(
            vaultAddress,
            mockToken,
            _startTimestamp,
            tokensPerEpoch,
            epochDuration,
            numberOfEpochs
        );
        vm.warp(_startTimestamp - 1); // before started

        uint256 _refundAmount = tokensPerEpoch * numberOfEpochs;
        uint256 balanceBefore = mockToken.balanceOf(address(this));

        vm.expectEmit();
        emit PromotionEnded(_promotionId, address(this), _refundAmount, 0);
        twabRewards.endPromotion(_promotionId, address(this));

        uint256 balanceAfter = mockToken.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, _refundAmount);

        uint8 latestEpochId = twabRewards.getPromotion(_promotionId).numberOfEpochs;
        assertEq(latestEpochId, twabRewards.getCurrentEpochId(_promotionId));
    }

    function testEndPromotion_UsersCanStillClaim() external {
        uint8 numEpochsPassed = 6;
        uint8[] memory epochIds = new uint8[](6);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 2;
        epochIds[3] = 3;
        epochIds[4] = 4;
        epochIds[5] = 5;

        uint256 totalShares = 1000e18;
        vm.startPrank(vaultAddress);
        twabController.mint(wallet1, uint96((totalShares * 3) / 4));
        twabController.mint(wallet2, uint96((totalShares * 1) / 4));
        vm.stopPrank();

        uint256 wallet1RewardAmount = numEpochsPassed * ((tokensPerEpoch * 3) / 4);
        uint256 wallet2RewardAmount = numEpochsPassed * ((tokensPerEpoch * 1) / 4);

        vm.warp(numEpochsPassed * epochDuration + promotionStartTime);

        uint256 _refundAmount = tokensPerEpoch * (numberOfEpochs - numEpochsPassed);
        uint256 balanceBefore = mockToken.balanceOf(address(this));
        twabRewards.endPromotion(promotionId, address(this));
        uint256 balanceAfter = mockToken.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, _refundAmount);

        balanceBefore = mockToken.balanceOf(wallet1);
        twabRewards.claimRewards(wallet1, promotionId, epochIds);
        balanceAfter = mockToken.balanceOf(wallet1);
        assertEq(balanceAfter - balanceBefore, wallet1RewardAmount);

        balanceBefore = mockToken.balanceOf(wallet2);
        twabRewards.claimRewards(wallet2, promotionId, epochIds);
        balanceAfter = mockToken.balanceOf(wallet2);
        assertEq(balanceAfter - balanceBefore, wallet2RewardAmount);
    }

    function testEndPromotion_OnlyPromotionCreator() external {
        vm.startPrank(wallet1);
        vm.expectRevert(abi.encodeWithSelector(OnlyPromotionCreator.selector, wallet1, address(this)));
        twabRewards.endPromotion(promotionId, wallet1);
        vm.stopPrank();
    }

    function testEndPromotion_PromotionInactive() external {
        vm.warp(promotionStartTime + epochDuration * numberOfEpochs);
        vm.expectRevert(abi.encodeWithSelector(PromotionInactive.selector, promotionId));
        twabRewards.endPromotion(promotionId, wallet1);
    }

    function testEndPromotion_PayeeZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(PayeeZeroAddress.selector));
        twabRewards.endPromotion(promotionId, address(0));
    }

    /* ============ destroyPromotion ============ */

    function testDestroyPromotion_TransfersExpectedAmount() external {
        uint8 numEpochsPassed = 2;
        uint8[] memory epochIds = new uint8[](2);
        epochIds[0] = 0;
        epochIds[1] = 1;

        uint256 totalShares = 1000e18;
        vm.startPrank(vaultAddress);
        twabController.mint(wallet1, uint96((totalShares * 3) / 4));
        twabController.mint(wallet2, uint96((totalShares * 1) / 4));
        vm.stopPrank();

        vm.warp(numEpochsPassed * epochDuration + promotionStartTime);

        twabRewards.claimRewards(wallet1, promotionId, epochIds);
        twabRewards.claimRewards(wallet2, promotionId, epochIds);

        vm.warp(epochDuration * numberOfEpochs + promotionStartTime + 60 days);

        uint256 _refundAmount = numberOfEpochs *
            tokensPerEpoch -
            mockToken.balanceOf(wallet1) -
            mockToken.balanceOf(wallet2);
        uint256 balanceBefore = mockToken.balanceOf(address(this));
        twabRewards.destroyPromotion(promotionId, address(this));
        uint256 balanceAfter = mockToken.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, _refundAmount);
    }

    function testDestroyPromotion_DoesNotExceedRewardBalance() external {
        // create another promotion
        uint256 _tokensPerEpoch = 1e18;
        uint256 amount = _tokensPerEpoch * numberOfEpochs;
        mockToken.mint(address(this), amount);
        mockToken.approve(address(twabRewards), amount);
        twabRewards.createPromotion(
            vaultAddress,
            mockToken,
            promotionStartTime,
            _tokensPerEpoch,
            epochDuration,
            numberOfEpochs
        );

        twabRewards.endPromotion(promotionId, address(this));

        vm.warp(promotionStartTime + 86400 * 61); // 61 days

        vm.expectEmit();
        emit PromotionDestroyed(promotionId, address(this), 0);
        twabRewards.destroyPromotion(promotionId, address(this));

        assertEq(mockToken.balanceOf(address(this)), tokensPerEpoch * numberOfEpochs);
        assertEq(mockToken.balanceOf(address(twabRewards)), amount);
    }

    function testDestroyPromotion_PayeeZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(PayeeZeroAddress.selector));
        twabRewards.destroyPromotion(promotionId, address(0));
    }

    function testDestroyPromotion_OnlyPromotionCreator() external {
        vm.expectRevert(abi.encodeWithSelector(OnlyPromotionCreator.selector, wallet1, address(this)));
        vm.startPrank(wallet1);
        twabRewards.destroyPromotion(promotionId, address(this));
        vm.stopPrank();
    }

    function testDestroyPromotion_GracePeriodActive() external {
        uint64 promotionEndTime = promotionStartTime + epochDuration * numberOfEpochs;
        vm.expectRevert(abi.encodeWithSelector(GracePeriodActive.selector, promotionEndTime + 86400 * 60));
        twabRewards.destroyPromotion(promotionId, address(this));
    }

    function testDestroyPromotion_GracePeriodActive_OneEpochPassed() external {
        uint64 promotionEndTime = promotionStartTime + epochDuration * numberOfEpochs;
        vm.warp(promotionStartTime + epochDuration); // 1 epoch passed
        vm.expectRevert(abi.encodeWithSelector(GracePeriodActive.selector, promotionEndTime + 86400 * 60));
        twabRewards.destroyPromotion(promotionId, address(this));
    }

    /* ============ extendPromotion ============ */

    function testExtendPromotion() external {
        uint8 addedEpochs = 6;
        uint256 additionalRewards = addedEpochs * tokensPerEpoch;

        mockToken.mint(address(this), additionalRewards);
        mockToken.approve(address(twabRewards), additionalRewards);

        vm.expectEmit();
        emit PromotionExtended(promotionId, addedEpochs);
        twabRewards.extendPromotion(promotionId, addedEpochs);

        assertEq(twabRewards.getPromotion(promotionId).numberOfEpochs, numberOfEpochs + addedEpochs);
        assertEq(mockToken.balanceOf(address(this)), 0);
        assertEq(mockToken.balanceOf(address(twabRewards)), tokensPerEpoch * (numberOfEpochs + addedEpochs));
    }

    function testExtendPromotion_PromotionInactive() external {
        vm.warp(promotionStartTime + numberOfEpochs * epochDuration); // end of promotion
        vm.expectRevert(abi.encodeWithSelector(PromotionInactive.selector, promotionId));
        twabRewards.extendPromotion(promotionId, 5);
    }

    function testExtendPromotion_InvalidPromotion() external {
        vm.expectRevert(abi.encodeWithSelector(InvalidPromotion.selector, promotionId + 1));
        twabRewards.extendPromotion(promotionId + 1, 1);
    }

    function testExtendPromotion_ExceedsMaxEpochs() external {
        vm.expectRevert(abi.encodeWithSelector(ExceedsMaxEpochs.selector, 250, numberOfEpochs, 255));
        twabRewards.extendPromotion(promotionId, 250);
    }

    /* ============ getPromotion ============ */

    function testGetPromotion() external {
        Promotion memory p = twabRewards.getPromotion(promotionId);
        assertEq(p.creator, address(this));
        assertEq(p.startTimestamp, promotionStartTime);
        assertEq(p.numberOfEpochs, numberOfEpochs);
        assertEq(p.vault, vaultAddress);
        assertEq(p.epochDuration, epochDuration);
        assertEq(p.createdAt, promotionCreatedAt);
        assertEq(address(p.token), address(mockToken));
        assertEq(p.tokensPerEpoch, tokensPerEpoch);
        assertEq(p.rewardsUnclaimed, tokensPerEpoch * numberOfEpochs);
    }

    function testGetPromotion_InvalidPromotion() external {
        vm.expectRevert(abi.encodeWithSelector(InvalidPromotion.selector, promotionId + 1));
        twabRewards.getPromotion(promotionId + 1);
    }

    /* ============ getRemainingRewards ============ */

    function testGetRemainingRewards() external {
        for (uint8 epoch; epoch < numberOfEpochs; epoch++) {
            vm.warp(promotionStartTime + epoch * epochDuration);
            assertEq(twabRewards.getRemainingRewards(promotionId), tokensPerEpoch * (numberOfEpochs - epoch));
        }
    }

    function testGetRemainingRewards_EndOfPromotion() external {
        vm.warp(promotionStartTime + epochDuration * numberOfEpochs);
        assertEq(twabRewards.getRemainingRewards(promotionId), 0);
    }

    /* ============ getCurrentEpochId ============ */

    function testGetCurrentEpochId() external {
        vm.warp(0);
        assertEq(twabRewards.getCurrentEpochId(promotionId), 0);

        vm.warp(promotionStartTime + epochDuration * 3);
        assertEq(twabRewards.getCurrentEpochId(promotionId), 3);

        vm.warp(promotionStartTime + epochDuration * 13);
        assertEq(twabRewards.getCurrentEpochId(promotionId), 13);
        assertGt(13, numberOfEpochs);
    }

    function testGetCurrentEpochId_InvalidPromotion() external {
        vm.expectRevert(abi.encodeWithSelector(InvalidPromotion.selector, promotionId + 1));
        twabRewards.getCurrentEpochId(promotionId + 1);
    }

    /* ============ getRewardsAmount ============ */

    function testGetRewardsAmount() external {
        uint8 numEpochsPassed = 6;
        uint8[] memory epochIds = new uint8[](6);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 2;
        epochIds[3] = 3;
        epochIds[4] = 4;
        epochIds[5] = 5;

        uint256 totalShares = 1000e18;
        vm.warp(0);
        vm.startPrank(vaultAddress);
        twabController.mint(wallet1, uint96((totalShares * 3) / 4));
        twabController.mint(wallet2, uint96((totalShares * 1) / 4));
        vm.stopPrank();

        uint256 wallet1RewardAmountPerEpoch = (tokensPerEpoch * 3) / 4;
        uint256 wallet2RewardAmountPerEpoch = (tokensPerEpoch * 1) / 4;

        vm.warp(promotionStartTime + epochDuration * numEpochsPassed);

        uint256[] memory wallet1Rewards = twabRewards.getRewardsAmount(wallet1, promotionId, epochIds);
        uint256[] memory wallet2Rewards = twabRewards.getRewardsAmount(wallet2, promotionId, epochIds);

        for (uint8 epoch = 0; epoch < numEpochsPassed; epoch++) {
            assertEq(wallet1Rewards[epoch], wallet1RewardAmountPerEpoch);
            assertEq(wallet2Rewards[epoch], wallet2RewardAmountPerEpoch);
        }
    }

    function testGetRewardsAmount_DelegateAmountChanged() external {
        uint8 numEpochsPassed = 6;
        uint8[] memory epochIds = new uint8[](6);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 2;
        epochIds[3] = 3;
        epochIds[4] = 4;
        epochIds[5] = 5;

        uint256 totalShares = 1000e18;
        vm.warp(0);
        vm.startPrank(vaultAddress);
        twabController.mint(wallet1, uint96((totalShares * 3) / 4));
        twabController.mint(wallet2, uint96((totalShares * 1) / 4));
        vm.stopPrank();

        // Delegate wallet2 balance halfway through epoch 2
        vm.warp(promotionStartTime + epochDuration * 2 + epochDuration / 2);
        vm.startPrank(wallet2);
        twabController.delegate(vaultAddress, wallet1);
        vm.stopPrank();

        vm.warp(promotionStartTime + epochDuration * numEpochsPassed);

        uint256[] memory wallet1Rewards = twabRewards.getRewardsAmount(wallet1, promotionId, epochIds);
        uint256[] memory wallet2Rewards = twabRewards.getRewardsAmount(wallet2, promotionId, epochIds);

        for (uint8 epoch = 0; epoch < numEpochsPassed; epoch++) {
            if (epoch < 2) {
                assertEq(wallet1Rewards[epoch], (tokensPerEpoch * 3) / 4);
                assertEq(wallet2Rewards[epoch], (tokensPerEpoch * 1) / 4);
            } else if (epoch == 2) {
                assertEq(wallet1Rewards[epoch], (tokensPerEpoch * 7) / 8);
                assertEq(wallet2Rewards[epoch], (tokensPerEpoch * 1) / 8);
            } else {
                assertEq(wallet1Rewards[epoch], tokensPerEpoch);
                assertEq(wallet2Rewards[epoch], 0);
            }
        }
    }

    function testGetRewardsAmount_AlreadyClaimed() external {
        uint8 numEpochsPassed = 6;
        uint8[] memory epochIds = new uint8[](6);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 2;
        epochIds[3] = 3;
        epochIds[4] = 4;
        epochIds[5] = 5;

        uint256 totalShares = 1000e18;
        vm.warp(0);
        vm.startPrank(vaultAddress);
        twabController.mint(wallet1, uint96((totalShares * 3) / 4));
        twabController.mint(wallet2, uint96((totalShares * 1) / 4));
        vm.stopPrank();

        // Claim epoch 1
        vm.warp(promotionStartTime + epochDuration * 2);
        uint8[] memory epochsToClaim = new uint8[](1);
        epochsToClaim[0] = 1;
        twabRewards.claimRewards(wallet1, promotionId, epochsToClaim);
        twabRewards.claimRewards(wallet2, promotionId, epochsToClaim);

        vm.warp(promotionStartTime + epochDuration * numEpochsPassed);

        uint256[] memory wallet1Rewards = twabRewards.getRewardsAmount(wallet1, promotionId, epochIds);
        uint256[] memory wallet2Rewards = twabRewards.getRewardsAmount(wallet2, promotionId, epochIds);

        for (uint8 epoch = 0; epoch < numEpochsPassed; epoch++) {
            if (epoch != 1) {
                assertEq(wallet1Rewards[epoch], (tokensPerEpoch * 3) / 4);
                assertEq(wallet2Rewards[epoch], (tokensPerEpoch * 1) / 4);
            } else {
                assertEq(wallet1Rewards[epoch], 0);
                assertEq(wallet2Rewards[epoch], 0);
            }
        }
    }

    function testGetRewardsAmount_NoDelegateBalance() external {
        uint8 numEpochsPassed = 6;
        uint8[] memory epochIds = new uint8[](6);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 2;
        epochIds[3] = 3;
        epochIds[4] = 4;
        epochIds[5] = 5;

        uint256 totalShares = 1000e18;
        vm.warp(0);
        vm.startPrank(vaultAddress);
        twabController.mint(wallet1, uint96((totalShares * 3) / 4));
        twabController.mint(wallet2, uint96((totalShares * 1) / 4));
        vm.stopPrank();

        uint256 wallet1RewardAmountPerEpoch = (tokensPerEpoch * 3) / 4;
        uint256 wallet2RewardAmountPerEpoch = (tokensPerEpoch * 1) / 4;
        uint256 wallet3RewardAmountPerEpoch = 0;

        vm.warp(promotionStartTime + epochDuration * numEpochsPassed);

        uint256[] memory wallet1Rewards = twabRewards.getRewardsAmount(wallet1, promotionId, epochIds);
        uint256[] memory wallet2Rewards = twabRewards.getRewardsAmount(wallet2, promotionId, epochIds);
        uint256[] memory wallet3Rewards = twabRewards.getRewardsAmount(wallet3, promotionId, epochIds);

        for (uint8 epoch = 0; epoch < numEpochsPassed; epoch++) {
            assertEq(wallet1Rewards[epoch], wallet1RewardAmountPerEpoch);
            assertEq(wallet2Rewards[epoch], wallet2RewardAmountPerEpoch);
            assertEq(wallet3Rewards[epoch], wallet3RewardAmountPerEpoch);
        }
    }

    function testGetRewardsAmount_NoSupply() external {
        uint8 numEpochsPassed = 3;
        uint8[] memory epochIds = new uint8[](3);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 2;

        vm.warp(promotionStartTime + epochDuration * numEpochsPassed);

        uint256[] memory wallet1Rewards = twabRewards.getRewardsAmount(wallet1, promotionId, epochIds);

        for (uint8 epoch = 0; epoch < numEpochsPassed; epoch++) {
            assertEq(wallet1Rewards[epoch], 0);
        }
    }

    function testGetRewardsAmount_EpochNotOver() external {
        uint8 numEpochsPassed = 3;
        uint8[] memory epochIds = new uint8[](3);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 2;

        vm.warp(promotionStartTime + epochDuration * (numEpochsPassed - 1) + 1);

        vm.expectRevert(
            abi.encodeWithSelector(EpochNotOver.selector, promotionStartTime + epochDuration * numEpochsPassed)
        );
        twabRewards.getRewardsAmount(wallet1, promotionId, epochIds);
    }

    function testGetRewardsAmount_InvalidEpochId() external {
        uint8[] memory epochIds = new uint8[](3);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = numberOfEpochs;

        vm.warp(promotionStartTime + epochDuration * (numberOfEpochs + 1));

        vm.expectRevert(abi.encodeWithSelector(InvalidEpochId.selector, numberOfEpochs, numberOfEpochs));
        twabRewards.getRewardsAmount(wallet1, promotionId, epochIds);
    }

    function testGetRewardsAmount_InvalidPromotion() external {
        uint8 numEpochsPassed = 3;
        uint8[] memory epochIds = new uint8[](3);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 2;

        vm.warp(promotionStartTime + epochDuration * numEpochsPassed);

        vm.expectRevert(abi.encodeWithSelector(InvalidPromotion.selector, promotionId + 1));
        twabRewards.getRewardsAmount(wallet1, promotionId + 1, epochIds);
    }

    // Originally used to test how rewards would react to non-aligned epochs.
    // Now we just want to make sure this fails since it can cause problems with TWAB.
    function testFailGetRewardsAmount_PromotionEpochNotAlignedWithTwab() external {
        // Create a promotion that is not aligned with the twab offset and period
        uint48 offsetStartTime = twabController.PERIOD_LENGTH() + twabController.PERIOD_OFFSET() - 60;
        uint48 offsetEpochDuration = 69;
        uint256 amount = tokensPerEpoch * numberOfEpochs;
        mockToken.mint(address(this), amount);
        mockToken.approve(address(twabRewards), amount);
        uint256 offsetPromotionId = twabRewards.createPromotion(
            vaultAddress,
            mockToken,
            offsetStartTime,
            tokensPerEpoch,
            offsetEpochDuration,
            numberOfEpochs
        );

        uint8[] memory epochIds = new uint8[](1);
        epochIds[0] = 0;

        uint256 totalShares = 1000e18;
        vm.warp(offsetStartTime);
        vm.startPrank(vaultAddress);
        twabController.mint(wallet1, uint96((totalShares * 3) / 8));
        vm.warp(offsetStartTime + offsetEpochDuration * 2);
        twabController.mint(wallet1, uint96((totalShares * 3) / 8));
        twabController.mint(wallet2, uint96((totalShares * 1) / 4));
        vm.stopPrank();

        vm.warp(2 * twabController.PERIOD_LENGTH() + twabController.PERIOD_OFFSET());

        uint256[] memory wallet1Rewards = twabRewards.getRewardsAmount(wallet1, offsetPromotionId, epochIds);
        uint256[] memory wallet2Rewards = twabRewards.getRewardsAmount(wallet2, offsetPromotionId, epochIds);

        assertGt(wallet1Rewards[0], 0);
        assertGt(wallet2Rewards[0], 0);

        assertGt(wallet1Rewards[0], wallet2Rewards[0]);

        assertLe(wallet1Rewards[0] + wallet2Rewards[0], tokensPerEpoch);
    }

    /* ============ claimRewards ============ */

    function testClaimRewards() external {
        uint8 numEpochsPassed = 3;
        uint8[] memory epochIds = new uint8[](3);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 2;

        uint256 totalShares = 1000e18;
        vm.warp(0);
        vm.startPrank(vaultAddress);
        twabController.mint(wallet1, uint96((totalShares * 3) / 4));
        twabController.mint(wallet2, uint96((totalShares * 1) / 4));
        vm.stopPrank();

        vm.warp(promotionStartTime + epochDuration * numEpochsPassed);
        vm.expectEmit();
        emit RewardsClaimed(promotionId, epochIds, wallet1, (numEpochsPassed * (tokensPerEpoch * 3)) / 4);
        twabRewards.claimRewards(wallet1, promotionId, epochIds);

        assertEq(mockToken.balanceOf(wallet1), (numEpochsPassed * (tokensPerEpoch * 3)) / 4);
    }

    function testClaimRewards_Multicall() external {
        uint8 numEpochsPassed = 3;
        uint8[] memory epochIds = new uint8[](3);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 2;

        uint256 totalShares = 1000e18;
        vm.warp(0);
        vm.startPrank(vaultAddress);
        twabController.mint(wallet1, uint96((totalShares * 3) / 4));
        twabController.mint(wallet2, uint96((totalShares * 1) / 4));
        vm.stopPrank();

        // Create second promotion with a different vault
        uint256 amount = tokensPerEpoch * numberOfEpochs;
        mockToken.mint(address(this), amount);
        mockToken.approve(address(twabRewards), amount);
        address secondVaultAddress = wallet3;
        uint256 secondPromotionId = twabRewards.createPromotion(
            secondVaultAddress,
            mockToken,
            promotionStartTime,
            tokensPerEpoch,
            epochDuration,
            numberOfEpochs
        );

        vm.warp(0);
        vm.startPrank(secondVaultAddress);
        twabController.mint(wallet1, 1e18);
        vm.stopPrank();

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(twabRewards.claimRewards.selector, wallet1, promotionId, epochIds);
        data[1] = abi.encodeWithSelector(twabRewards.claimRewards.selector, wallet1, secondPromotionId, epochIds);

        vm.warp(promotionStartTime + epochDuration * numEpochsPassed);
        vm.expectEmit();
        emit RewardsClaimed(promotionId, epochIds, wallet1, (numEpochsPassed * (tokensPerEpoch * 3)) / 4);
        vm.expectEmit();
        emit RewardsClaimed(secondPromotionId, epochIds, wallet1, tokensPerEpoch * 3);
        twabRewards.multicall(data);

        assertEq(mockToken.balanceOf(wallet1), tokensPerEpoch * 3 + (numEpochsPassed * (tokensPerEpoch * 3)) / 4);
    }

    function testClaimRewards_DecreasedDelegateBalance() external {
        uint8[] memory epochIds = new uint8[](1);
        epochIds[0] = 0;

        uint256 totalShares = 1000e18;
        vm.warp(0);
        vm.startPrank(vaultAddress);
        twabController.mint(wallet1, uint96((totalShares * 3) / 4));
        twabController.mint(wallet2, uint96((totalShares * 1) / 4));
        vm.stopPrank();

        // Decrease wallet1 delegate balance halfway through epoch
        vm.warp(promotionStartTime + epochDuration / 2);
        vm.startPrank(wallet1);
        twabController.delegate(vaultAddress, wallet2);
        vm.stopPrank();

        vm.warp(promotionStartTime + epochDuration);
        vm.expectEmit();
        emit RewardsClaimed(promotionId, epochIds, wallet1, (tokensPerEpoch * 3) / 8);
        twabRewards.claimRewards(wallet1, promotionId, epochIds);

        assertEq(mockToken.balanceOf(wallet1), (tokensPerEpoch * 3) / 8);
    }

    function testClaimRewards_NoDelegateBalance() external {
        uint8 numEpochsPassed = 3;
        uint8[] memory epochIds = new uint8[](3);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 2;

        uint256 totalShares = 1000e18;
        vm.warp(0);
        vm.startPrank(vaultAddress);
        twabController.mint(wallet1, uint96((totalShares * 3) / 4));
        twabController.mint(wallet2, uint96((totalShares * 1) / 4));
        vm.stopPrank();

        vm.warp(promotionStartTime + epochDuration * numEpochsPassed);
        vm.expectEmit();
        emit RewardsClaimed(promotionId, epochIds, wallet3, 0);
        twabRewards.claimRewards(wallet3, promotionId, epochIds);

        assertEq(mockToken.balanceOf(wallet3), 0);
    }

    function testClaimRewards_NoSupply() external {
        uint8 numEpochsPassed = 3;
        uint8[] memory epochIds = new uint8[](3);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 2;

        vm.warp(promotionStartTime + epochDuration * numEpochsPassed);
        vm.expectEmit();
        emit RewardsClaimed(promotionId, epochIds, wallet1, 0);
        twabRewards.claimRewards(wallet1, promotionId, epochIds);

        assertEq(mockToken.balanceOf(wallet1), 0);
    }

    function testClaimRewards_InvalidPromotion() external {
        uint8 numEpochsPassed = 3;
        uint8[] memory epochIds = new uint8[](3);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 2;

        vm.warp(promotionStartTime + epochDuration * numEpochsPassed);
        vm.expectRevert(abi.encodeWithSelector(InvalidPromotion.selector, promotionId + 1));
        twabRewards.claimRewards(wallet1, promotionId + 1, epochIds);
    }

    function testClaimRewards_EpochNotOver() external {
        uint8 numEpochsPassed = 3;
        uint8[] memory epochIds = new uint8[](3);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 3; // 4th epoch

        vm.warp(promotionStartTime + epochDuration * numEpochsPassed);
        vm.expectRevert(abi.encodeWithSelector(EpochNotOver.selector, promotionStartTime + epochDuration * 4));
        twabRewards.claimRewards(wallet1, promotionId, epochIds);
    }

    function testClaimRewards_RewardsAlreadyClaimed() external {
        uint8 numEpochsPassed = 3;
        uint8[] memory epochIds = new uint8[](3);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = 2;

        uint256 totalShares = 1000e18;
        vm.warp(0);
        vm.startPrank(vaultAddress);
        twabController.mint(wallet1, uint96((totalShares * 3) / 4));
        twabController.mint(wallet2, uint96((totalShares * 1) / 4));
        vm.stopPrank();

        vm.warp(promotionStartTime + epochDuration * numEpochsPassed);
        twabRewards.claimRewards(wallet1, promotionId, epochIds);

        // Try to claim again:
        uint8[] memory reclaimEpochId = new uint8[](1);
        reclaimEpochId[0] = 0;
        vm.expectRevert(abi.encodeWithSelector(RewardsAlreadyClaimed.selector, promotionId, wallet1, 0));
        twabRewards.claimRewards(wallet1, promotionId, reclaimEpochId);

        reclaimEpochId[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(RewardsAlreadyClaimed.selector, promotionId, wallet1, 1));
        twabRewards.claimRewards(wallet1, promotionId, reclaimEpochId);

        reclaimEpochId[0] = 2;
        vm.expectRevert(abi.encodeWithSelector(RewardsAlreadyClaimed.selector, promotionId, wallet1, 2));
        twabRewards.claimRewards(wallet1, promotionId, reclaimEpochId);
    }

    function testClaimRewards_InvalidEpochId() external {
        uint8[] memory epochIds = new uint8[](3);
        epochIds[0] = 0;
        epochIds[1] = 1;
        epochIds[2] = numberOfEpochs;

        vm.warp(promotionStartTime + epochDuration * (numberOfEpochs + 1));
        vm.expectRevert(abi.encodeWithSelector(InvalidEpochId.selector, numberOfEpochs, numberOfEpochs));
        twabRewards.claimRewards(wallet1, promotionId, epochIds);
    }

    /* ============ Helpers ============ */

    function createPromotion() public returns (uint256) {
        uint256 amount = tokensPerEpoch * numberOfEpochs;
        mockToken.mint(address(this), amount);
        mockToken.approve(address(twabRewards), amount);
        return
            twabRewards.createPromotion(
                vaultAddress,
                mockToken,
                promotionStartTime,
                tokensPerEpoch,
                epochDuration,
                numberOfEpochs
            );
    }
}
