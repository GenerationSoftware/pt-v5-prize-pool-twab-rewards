// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import { Multicall } from "openzeppelin-contracts/utils/Multicall.sol";
import { TwabController } from "pt-v5-twab-controller/TwabController.sol";

import { IPrizePool } from "./external/IPrizePool.sol";
import { IPrizePoolTwabRewards, Promotion } from "./interfaces/IPrizePoolTwabRewards.sol";

/* ============ Custom Errors ============ */

/// @notice Thrown when the TwabController address set in the constructor is the zero address.
error TwabControllerZeroAddress();

/// @notice Thrown when a promotion is created with an emission of zero tokens per epoch.
error ZeroTokensPerEpoch();

/// @notice Thrown when the number of epochs is zero when it must be greater than zero.
error ZeroEpochs();

/// @notice Thrown if the tokens received at the creation of a promotion is less than the expected amount.
/// @param received The amount of tokens received
/// @param expected The expected amount of tokens
error TokensReceivedLessThanExpected(uint256 received, uint256 expected);

/// @notice Thrown if the address to receive tokens from ending or destroying a promotion is the zero address.
error PayeeZeroAddress();

/// @notice Thrown if an action cannot be completed while the grace period is active.
/// @param gracePeriodEndTimestamp The end timestamp of the grace period
error GracePeriodActive(uint256 gracePeriodEndTimestamp);

/// @notice Thrown if a promotion extension would exceed the max number of epochs.
/// @param epochExtension The number of epochs to extend the promotion by
/// @param currentEpochs The current number of epochs in the promotion
/// @param maxEpochs The max number of epochs that a promotion can have
error ExceedsMaxEpochs(uint8 epochExtension, uint8 currentEpochs, uint8 maxEpochs);

/// @notice Thrown if rewards for the promotion epoch have already been claimed by the user.
/// @param promotionId The ID of the promotion
/// @param user The address of the user that the rewards are being claimed for
/// @param epochId The epoch that rewards are being claimed from
error RewardsAlreadyClaimed(uint256 promotionId, address user, uint8 epochId);

/// @notice Thrown if a promotion is no longer active.
/// @param promotionId The ID of the promotion
error PromotionInactive(uint256 promotionId);

/// @notice Thrown if the sender is not the promotion creator on a creator-only action.
/// @param sender The address of the sender
/// @param creator The address of the creator
error OnlyPromotionCreator(address sender, address creator);

/// @notice Thrown if the promotion is invalid or not initialized.
/// @param promotionId The ID of the promotion
error InvalidPromotion(uint256 promotionId);

/// @notice Thrown if the rewards for an epoch are being claimed before the epoch is over.
/// @param epochEndTimestamp The time at which the epoch will end
error EpochNotOver(uint64 epochEndTimestamp);

/// @notice Thrown if an epoch is outside the range of epochs in a promotion.
/// @param epochId The ID of the epoch
/// @param numberOfEpochs The number of epochs in the promotion
error InvalidEpochId(uint8 epochId, uint8 numberOfEpochs);

/// @notice Thrown if the given prize pool address is zero
error PrizePoolZeroAddress();

/// @notice Thrown when the epoch duration is less than the draw period.
error EpochDurationLtDrawPeriod();
    
/// @notice Thrown when the epoch duration is not a multiple of the draw period.
error EpochDurationNotMultipleOfDrawPeriod();
    
/// @notice Thrown when the start time is less than the first draw opens at time.
error StartTimeLtFirstDrawOpensAt();
    
/// @notice Thrown when the start time is not aligned with the draws.
error StartTimeNotAlignedWithDraws();

/**
 * @title PoolTogether V5 PrizePoolTwabRewards
 * @author G9 Software Inc.
 * @notice Contract to distribute rewards to depositors across all vaults that contribute to a Prize Pool.
 * The contract supports multiple reward "promotions". Each promotion can define a different reward token,
 * start time, epoch duration, and number of epochs. Promotions divide time into evenly sized epochs; and users 
 * can claim rewards for each epoch. The amount each user gets is based on their portion of the Vault twab * vault contribution,
 * where the vault contribution is fraction of prize pool prizes that the vault contributed during the epoch.
 * @dev This contract does not support the use of fee on transfer tokens.
 */
contract PrizePoolTwabRewards is IPrizePoolTwabRewards, Multicall {
    using SafeERC20 for IERC20;

    /* ============ Global Variables ============ */

    /// @notice TwabController contract from which the promotions read time-weighted average balances from.
    TwabController public immutable twabController;

    /// @notice The Prize Pool used to compute the vault contributions.
    IPrizePool public immutable prizePool;

    uint48 internal immutable _drawPeriodSeconds;
    uint48 internal immutable _firstDrawOpensAt;

    address constant SPONSORSHIP_ADDRESS = address(1);

    /// @notice Period during which the promotion owner can't destroy a promotion.
    uint32 public constant GRACE_PERIOD = 60 days;

    /// @notice Settings of each promotion.
    mapping(uint256 => Promotion) internal _promotions;

    /**
     * @notice Latest recorded promotion id.
     * @dev Starts at 0 and is incremented by 1 for each new promotion. So the first promotion will have id 1, the second 2, etc.
     */
    uint256 public latestPromotionId;

    /**
     * @notice Keeps track of claimed rewards per user.
     * @dev _claimedEpochs[promotionId][user] => claimedEpochs
     * @dev We pack epochs claimed by a user into a uint256. So we can't store more than 256 epochs.
     */
    mapping(uint256 promotionId => mapping(address vault => mapping(address user => uint256 claimMask))) internal _claimedEpochs;

    /* ============ Events ============ */

    /**
     * @notice Emitted when a promotion is created.
     * @param promotionId Id of the newly created promotion
     * @param token The token that will be rewarded from the promotion
     * @param startTimestamp The timestamp at which the promotion starts
     * @param tokensPerEpoch The number of tokens emitted per epoch
     * @param epochDuration The duration of epoch in seconds
     * @param initialNumberOfEpochs The initial number of epochs the promotion is set to run for
     */
    event PromotionCreated(
        uint256 indexed promotionId,
        IERC20 indexed token,
        uint64 startTimestamp,
        uint256 tokensPerEpoch,
        uint48 epochDuration,
        uint8 initialNumberOfEpochs
    );

    /**
     * @notice Emitted when a promotion is ended.
     * @param promotionId Id of the promotion being ended
     * @param recipient Address of the recipient that will receive the remaining rewards
     * @param amount Amount of tokens transferred to the recipient
     * @param epochNumber Epoch number at which the promotion ended
     */
    event PromotionEnded(uint256 indexed promotionId, address indexed recipient, uint256 amount, uint8 epochNumber);

    /**
     * @notice Emitted when a promotion is destroyed.
     * @param promotionId Id of the promotion being destroyed
     * @param recipient Address of the recipient that will receive the unclaimed rewards
     * @param amount Amount of tokens transferred to the recipient
     */
    event PromotionDestroyed(uint256 indexed promotionId, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when a promotion is extended.
     * @param promotionId Id of the promotion being extended
     * @param numberOfEpochs Number of epochs the promotion has been extended by
     */
    event PromotionExtended(uint256 indexed promotionId, uint256 numberOfEpochs);

    /**
     * @notice Emitted when rewards have been claimed.
     * @param promotionId Id of the promotion for which epoch rewards were claimed
     * @param epochIds Ids of the epochs being claimed
     * @param user Address of the user for which the rewards were claimed
     * @param amount Amount of tokens transferred to the recipient address
     */
    event RewardsClaimed(uint256 indexed promotionId, uint8[] epochIds, address indexed vault, address indexed user, uint256 amount);

    /* ============ Constructor ============ */

    /**
     * @notice Constructor of the contract.
     * @param _twabController The TwabController contract to reference for vault balance and supply
     * @param _prizePool The PrizePool contract to use for prize contributions
     */
    constructor(TwabController _twabController, IPrizePool _prizePool) {
        if (address(0) == address(_twabController)) revert TwabControllerZeroAddress();
        if (address(0) == address(_prizePool)) revert PrizePoolZeroAddress();
        twabController = _twabController;
        prizePool = _prizePool;
        _drawPeriodSeconds = prizePool.drawPeriodSeconds();
        _firstDrawOpensAt = prizePool.firstDrawOpensAt();
    }

    /* ============ External Functions ============ */

    /**
     * @inheritdoc IPrizePoolTwabRewards
     * @dev For sake of simplicity, `msg.sender` will be the creator of the promotion.
     * @dev `_latestPromotionId` starts at 0 and is incremented by 1 for each new promotion.
     * So the first promotion will have id 1, the second 2, etc.
     * @dev The transaction will revert if the amount of reward tokens provided is not equal to `_tokensPerEpoch * _numberOfEpochs`.
     * This scenario could happen if the token supplied is a fee on transfer one.
     */
    function createPromotion(
        IERC20 _token,
        uint48 _startTimestamp,
        uint256 _tokensPerEpoch,
        uint48 _epochDuration,
        uint8 _numberOfEpochs
    ) external override returns (uint256) {
        if (_tokensPerEpoch == 0) revert ZeroTokensPerEpoch();
        _requireNumberOfEpochs(_numberOfEpochs);
        if (_epochDuration < _drawPeriodSeconds) revert EpochDurationLtDrawPeriod();
        if (_epochDuration % _drawPeriodSeconds != 0) revert EpochDurationNotMultipleOfDrawPeriod();
        if (_startTimestamp < _firstDrawOpensAt) revert StartTimeLtFirstDrawOpensAt();
        if ((_startTimestamp - _firstDrawOpensAt) % _drawPeriodSeconds != 0) revert StartTimeNotAlignedWithDraws();

        // ensure that this contract isn't eligible to win any prizes
        if (twabController.delegateOf(address(_token), address(this)) != SPONSORSHIP_ADDRESS) {
            twabController.delegate(address(_token), SPONSORSHIP_ADDRESS);
        }

        uint256 _nextPromotionId = latestPromotionId + 1;
        latestPromotionId = _nextPromotionId;

        uint256 _amount = _tokensPerEpoch * _numberOfEpochs;

        _promotions[_nextPromotionId] = Promotion({
            creator: msg.sender,
            startTimestamp: _startTimestamp,
            numberOfEpochs: _numberOfEpochs,
            epochDuration: _epochDuration,
            createdAt: uint48(block.timestamp),
            token: _token,
            tokensPerEpoch: _tokensPerEpoch,
            rewardsUnclaimed: _amount
        });

        uint256 _beforeBalance = _token.balanceOf(address(this));

        _token.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 _afterBalance = _token.balanceOf(address(this));

        if (_afterBalance < _beforeBalance + _amount)
            revert TokensReceivedLessThanExpected(_afterBalance - _beforeBalance, _amount);

        emit PromotionCreated(
            _nextPromotionId,
            _token,
            _startTimestamp,
            _tokensPerEpoch,
            _epochDuration,
            _numberOfEpochs
        );

        return _nextPromotionId;
    }

    /// @inheritdoc IPrizePoolTwabRewards
    function endPromotion(uint256 _promotionId, address _to) external override returns (bool) {
        if (address(0) == _to) revert PayeeZeroAddress();

        Promotion memory _promotion = _getPromotion(_promotionId);
        _requirePromotionCreator(_promotion);
        _requirePromotionActive(_promotionId, _promotion);

        uint8 _epochNumber = uint8(_getCurrentEpochId(_promotion));
        _promotions[_promotionId].numberOfEpochs = _epochNumber;

        uint256 _remainingRewards = _getRemainingRewards(_promotion);
        _promotions[_promotionId].rewardsUnclaimed -= _remainingRewards;

        _promotion.token.safeTransfer(_to, _remainingRewards);

        emit PromotionEnded(_promotionId, _to, _remainingRewards, _epochNumber);

        return true;
    }

    /// @inheritdoc IPrizePoolTwabRewards
    function destroyPromotion(uint256 _promotionId, address _to) external override returns (bool) {
        if (address(0) == _to) revert PayeeZeroAddress();

        Promotion memory _promotion = _getPromotion(_promotionId);
        _requirePromotionCreator(_promotion);

        uint256 _promotionEndTimestamp = _getPromotionEndTimestamp(_promotion);
        uint256 _promotionCreatedAt = _promotion.createdAt;

        uint256 _gracePeriodEndTimestamp = (
            _promotionEndTimestamp < _promotionCreatedAt ? _promotionCreatedAt : _promotionEndTimestamp
        ) + GRACE_PERIOD;

        if (block.timestamp < _gracePeriodEndTimestamp) revert GracePeriodActive(_gracePeriodEndTimestamp);

        uint256 _rewardsUnclaimed = _promotion.rewardsUnclaimed;
        delete _promotions[_promotionId];

        _promotion.token.safeTransfer(_to, _rewardsUnclaimed);

        emit PromotionDestroyed(_promotionId, _to, _rewardsUnclaimed);

        return true;
    }

    /// @inheritdoc IPrizePoolTwabRewards
    function extendPromotion(uint256 _promotionId, uint8 _numberOfEpochs) external override returns (bool) {
        _requireNumberOfEpochs(_numberOfEpochs);

        Promotion memory _promotion = _getPromotion(_promotionId);
        _requirePromotionActive(_promotionId, _promotion);

        uint8 _currentNumberOfEpochs = _promotion.numberOfEpochs;

        if (_numberOfEpochs > (type(uint8).max - _currentNumberOfEpochs))
            revert ExceedsMaxEpochs(_numberOfEpochs, _currentNumberOfEpochs, type(uint8).max);

        _promotions[_promotionId].numberOfEpochs = _currentNumberOfEpochs + _numberOfEpochs;

        uint256 _amount = _numberOfEpochs * _promotion.tokensPerEpoch;

        _promotions[_promotionId].rewardsUnclaimed += _amount;
        _promotion.token.safeTransferFrom(msg.sender, address(this), _amount);

        emit PromotionExtended(_promotionId, _numberOfEpochs);

        return true;
    }

    /// @inheritdoc IPrizePoolTwabRewards
    function claimRewards(
        address _vault,
        address _user,
        uint256 _promotionId,
        uint8[] calldata _epochIds
    ) external override returns (uint256) {
        Promotion memory _promotion = _getPromotion(_promotionId);

        uint256 _rewardsAmount;
        uint256 _userClaimedEpochs = _claimedEpochs[_promotionId][_vault][_user];
        uint256 _epochIdsLength = _epochIds.length;

        for (uint256 index = 0; index < _epochIdsLength; index++) {
            uint8 _epochId = _epochIds[index];

            if (_isClaimedEpoch(_userClaimedEpochs, _epochId))
                revert RewardsAlreadyClaimed(_promotionId, _user, _epochId);

            _rewardsAmount += _calculateRewardAmount(_vault, _user, _promotion, _epochId);
            _userClaimedEpochs = _updateClaimedEpoch(_userClaimedEpochs, _epochId);
        }

        _claimedEpochs[_promotionId][_vault][_user] = _userClaimedEpochs;
        _promotions[_promotionId].rewardsUnclaimed -= _rewardsAmount;

        _promotion.token.safeTransfer(_user, _rewardsAmount);

        emit RewardsClaimed(_promotionId, _epochIds, _vault, _user, _rewardsAmount);

        return _rewardsAmount;
    }

    /// @inheritdoc IPrizePoolTwabRewards
    function getPromotion(uint256 _promotionId) external view override returns (Promotion memory) {
        return _getPromotion(_promotionId);
    }

    /// @inheritdoc IPrizePoolTwabRewards
    /// @dev Epoch ids and their boolean values are tightly packed and stored in a uint256, so epoch id starts at 0.
    function getCurrentEpochId(uint256 _promotionId) external view override returns (uint256) {
        return _getCurrentEpochId(_getPromotion(_promotionId));
    }

    /// @inheritdoc IPrizePoolTwabRewards
    function getRemainingRewards(uint256 _promotionId) external view override returns (uint256) {
        return _getRemainingRewards(_getPromotion(_promotionId));
    }

    /// @inheritdoc IPrizePoolTwabRewards
    function getRewardsAmount(
        address _vault,
        address _user,
        uint256 _promotionId,
        uint8[] calldata _epochIds
    ) external view override returns (uint256[] memory) {
        Promotion memory _promotion = _getPromotion(_promotionId);

        uint256 _epochIdsLength = _epochIds.length;
        uint256[] memory _rewardsAmount = new uint256[](_epochIdsLength);

        for (uint256 index = 0; index < _epochIdsLength; index++) {
            if (_isClaimedEpoch(_claimedEpochs[_promotionId][_vault][_user], _epochIds[index])) {
                _rewardsAmount[index] = 0;
            } else {
                _rewardsAmount[index] = _calculateRewardAmount(_vault, _user, _promotion, _epochIds[index]);
            }
        }

        return _rewardsAmount;
    }

    /* ============ Internal Functions ============ */

    /**
     * @notice Allow a promotion to be created or extended only by a positive number of epochs.
     * @param _numberOfEpochs Number of epochs to check
     */
    function _requireNumberOfEpochs(uint8 _numberOfEpochs) internal pure {
        if (0 == _numberOfEpochs) revert ZeroEpochs();
    }

    /**
     * @notice Requires that a promotion is active.
     * @param _promotion Promotion to check
     */
    function _requirePromotionActive(uint256 _promotionId, Promotion memory _promotion) internal view {
        if (_getPromotionEndTimestamp(_promotion) <= block.timestamp) revert PromotionInactive(_promotionId);
    }

    /**
     * @notice Requires that msg.sender is the promotion creator.
     * @param _promotion Promotion to check
     */
    function _requirePromotionCreator(Promotion memory _promotion) internal view {
        if (msg.sender != _promotion.creator) revert OnlyPromotionCreator(msg.sender, _promotion.creator);
    }

    /**
     * @notice Get settings for a specific promotion.
     * @dev Will revert if the promotion does not exist.
     * @param _promotionId Promotion id to get settings for
     * @return Promotion settings
     */
    function _getPromotion(uint256 _promotionId) internal view returns (Promotion memory) {
        Promotion memory _promotion = _promotions[_promotionId];
        if (address(0) == _promotion.creator) revert InvalidPromotion(_promotionId);
        return _promotion;
    }

    /**
     * @notice Compute promotion end timestamp.
     * @param _promotion Promotion to compute end timestamp for
     * @return Promotion end timestamp
     */
    function _getPromotionEndTimestamp(Promotion memory _promotion) internal pure returns (uint256) {
        unchecked {
            return _promotion.startTimestamp + (_promotion.epochDuration * _promotion.numberOfEpochs);
        }
    }

    /**
     * @notice Get the current epoch id of a promotion.
     * @dev Epoch ids and their boolean values are tightly packed and stored in a uint256, so epoch id starts at 0.
     * @dev We return the current epoch id if the promotion has not ended.
     * If the current timestamp is before the promotion start timestamp, we return 0.
     * Otherwise, we return the epoch id at the current timestamp. This could be greater than the number of epochs of the promotion.
     * @param _promotion Promotion to get current epoch for
     * @return Epoch id
     */
    function _getCurrentEpochId(Promotion memory _promotion) internal view returns (uint256) {
        uint256 _currentEpochId;

        if (block.timestamp > _promotion.startTimestamp) {
            unchecked {
                _currentEpochId = (block.timestamp - _promotion.startTimestamp) / _promotion.epochDuration;
            }
        }

        return _currentEpochId;
    }

    function calculateDrawIdAt(uint64 _timestamp) public view returns (uint24) {
        if (_timestamp < _firstDrawOpensAt) return 0;
        else return uint24((_timestamp - _firstDrawOpensAt) / _drawPeriodSeconds);
    }

    /**
     * @notice Get reward amount for a specific user.
     * @dev Rewards can only be calculated once the epoch is over.
     * @dev Will revert if `_epochId` is over the total number of epochs or if epoch is not over.
     * @dev Will return 0 if the user average balance in the vault is 0.
     * @param _vault Vault to get reward amount for
     * @param _user User to get reward amount for
     * @param _promotion Promotion from which the epoch is
     * @param _epochId Epoch id to get reward amount for
     * @return Reward amount
     */
    function _calculateRewardAmount(
        address _vault,
        address _user,
        Promotion memory _promotion,
        uint8 _epochId
    ) internal view returns (uint256) {
        uint48 _epochDuration = _promotion.epochDuration;

        (
            uint48 _epochStartTimestamp,
            uint48 _epochEndTimestamp,
            uint24 _epochStartDrawId,
            uint24 _epochEndDrawId
        ) = epochRanges(_promotion.startTimestamp, _epochDuration, _epochId);

        if (block.timestamp < _epochEndTimestamp) revert EpochNotOver(_epochEndTimestamp);
        if (_epochId >= _promotion.numberOfEpochs) revert InvalidEpochId(_epochId, _promotion.numberOfEpochs);

        uint256 _userAverage = twabController.getTwabBetween(
            _vault,
            _user,
            _epochStartTimestamp,
            _epochEndTimestamp
        );

        if (_userAverage > 0) {
            uint256 _vaultContributed = prizePool.getContributedBetween(_vault, _epochStartDrawId, _epochEndDrawId);
            if (_vaultContributed > 0) {
                uint256 _averageTotalSupply = twabController.getTotalSupplyTwabBetween(
                    _vault,
                    _epochStartTimestamp,
                    _epochEndTimestamp
                );
                uint256 _totalContributed = prizePool.getTotalContributedBetween(_epochStartDrawId, _epochEndDrawId);
                return (_promotion.tokensPerEpoch * _userAverage * _vaultContributed) / (_averageTotalSupply * _totalContributed);
            }
        }
        return 0;
    }

    /**
     * @notice Get the time and draw ranges for an epoch
     * @param _promotionId Id of the promotion
     * @param _epochId Id of the epoch to get the ranges for
     * @return epochStartTimestamp Start timestamp of the epoch
     * @return epochEndTimestamp End timestamp of the epoch
     * @return epochStartDrawId Start draw id of the epoch
     * @return epochEndDrawId End draw id of the epoch
     */
    function epochRangesForPromotion(
        uint256 _promotionId,
        uint8 _epochId
    ) public view returns (
        uint48 epochStartTimestamp,
        uint48 epochEndTimestamp,
        uint24 epochStartDrawId,
        uint24 epochEndDrawId
    ) {
        Promotion memory promotion = _promotions[_promotionId];
        return epochRanges(promotion.startTimestamp, promotion.epochDuration, _epochId);
    }

    /**
     * @notice Get the time and draw ranges for an epoch
     * @param _promotionStartTimestamp Start timestamp of the promotion
     * @param _promotionEpochDuration Duration of an epoch in the promotion
     * @param _epochId Id of the epoch to get the ranges for
     * @return epochStartTimestamp Start timestamp of the epoch
     * @return epochEndTimestamp End timestamp of the epoch
     * @return epochStartDrawId Start draw id of the epoch
     * @return epochEndDrawId End draw id of the epoch
     */
    function epochRanges(
        uint48 _promotionStartTimestamp,
        uint48 _promotionEpochDuration,
        uint8 _epochId
    ) public view returns (
        uint48 epochStartTimestamp,
        uint48 epochEndTimestamp,
        uint24 epochStartDrawId,
        uint24 epochEndDrawId
    ) {
        epochStartTimestamp = _promotionStartTimestamp + (_promotionEpochDuration * _epochId);
        epochEndTimestamp = epochStartTimestamp + _promotionEpochDuration;
        epochStartDrawId = calculateDrawIdAt(epochStartTimestamp);
        epochEndDrawId = epochStartDrawId + uint24(_promotionEpochDuration / _drawPeriodSeconds) - 1;
    }

    /**
     * @notice Get the total amount of tokens left to be rewarded.
     * @param _promotion Promotion to get the total amount of tokens left to be rewarded for
     * @return Amount of tokens left to be rewarded
     */
    function _getRemainingRewards(Promotion memory _promotion) internal view returns (uint256) {
        if (block.timestamp >= _getPromotionEndTimestamp(_promotion)) {
            return 0;
        }

        return _promotion.tokensPerEpoch * (_promotion.numberOfEpochs - _getCurrentEpochId(_promotion));
    }

    /**
    * @notice Set boolean value for a specific epoch.
    * @dev Bits are stored in a uint256 from right to left.
        Let's take the example of the following 8 bits word. 0110 0011
        To set the boolean value to 1 for the epoch id 2, we need to create a mask by shifting 1 to the left by 2 bits.
        We get: 0000 0001 << 2 = 0000 0100
        We then OR the mask with the word to set the value.
        We get: 0110 0011 | 0000 0100 = 0110 0111
    * @param _userClaimedEpochs Tightly packed epoch ids with their boolean values
    * @param _epochId Id of the epoch to set the boolean for
    * @return Tightly packed epoch ids with the newly boolean value set
    */
    function _updateClaimedEpoch(uint256 _userClaimedEpochs, uint8 _epochId) internal pure returns (uint256) {
        return _userClaimedEpochs | (uint256(1) << _epochId);
    }

    /**
    * @notice Check if rewards of an epoch for a given promotion have already been claimed by the user.
    * @dev Bits are stored in a uint256 from right to left.
        Let's take the example of the following 8 bits word. 0110 0111
        To retrieve the boolean value for the epoch id 2, we need to shift the word to the right by 2 bits.
        We get: 0110 0111 >> 2 = 0001 1001
        We then get the value of the last bit by masking with 1.
        We get: 0001 1001 & 0000 0001 = 0000 0001 = 1
        We then return the boolean value true since the last bit is 1.
    * @param _userClaimedEpochs Record of epochs already claimed by the user
    * @param _epochId Epoch id to check
    * @return true if the rewards have already been claimed for the given epoch, false otherwise
     */
    function _isClaimedEpoch(uint256 _userClaimedEpochs, uint8 _epochId) internal pure returns (bool) {
        return (_userClaimedEpochs >> _epochId) & uint256(1) == 1;
    }
}
