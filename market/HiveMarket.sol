// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IHiveStrategy} from "../interfaces/IHiveStrategy.sol";

/// @notice An ERC4626 market that accrues a configured annual reward rate on accounted assets.
contract HiveMarket is ERC4626, Ownable, Pausable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant YEAR = 365 days;
    uint256 public constant REWARD_PRECISION = 1e18;

    // The optional strategy where market assets are deployed.
    IHiveStrategy public hiveStrategy;

    uint256 public apyBps;
    uint256 public totalRewardsAccrued;
    uint256 public lastAccrualTime;
    uint256 public accRewardPerShare;

    // Tracks callers that have deposited or minted at least once. Entries are never removed.
    EnumerableSet.AddressSet private userSet;

    // Principal plus rewards that have already been recognized by the market.
    uint256 public accountedAssets;
    uint256 public withdrawTolerance;
    uint256 public maxApyBps = 10_000;

    error ZeroAddress();
    error WrongStrategy();
    error CannotRescueAsset();
    error InsufficientLiquidity();
    error ApyBpsExceedsMaximum(uint256 requested, uint256 maximum);
    error MaxApyBpsBelowCurrentApy(uint256 requested, uint256 currentApy);

    event ApyBpsChanged(uint256 oldApy, uint256 newApy);
    event MaxApyBpsChanged(uint256 oldMaxApyBps, uint256 newMaxApyBps);
    event RewardsAccrued(
        uint256 reward,
        uint256 totalRewardsAccrued,
        uint256 accRewardPerShare
    );
    event RewardsFunded(address from, uint256 amount);
    event ExcessRewardsWithdrawn(address indexed to, uint256 amount);
    event ChangeStrategy(address oldHiveStrategy, address newHiveStrategy);
    event TokenRescued(
        address indexed token,
        address indexed to,
        uint256 amount
    );
    event WithdrawToleranceChanged(uint256 oldTolerance, uint256 newTolerance);

    constructor(
        IERC20 _assets,
        uint256 _initialApyBps,
        string memory _receiptName,
        string memory _receiptSymbol,
        address _owner
    ) ERC20(_receiptName, _receiptSymbol) ERC4626(_assets) Ownable(_owner) {
        if (address(_assets) == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }

        apyBps = _initialApyBps;
        lastAccrualTime = block.timestamp;
    }

    function getUserSetLength() public view onlyOwner returns (uint256) {
        return userSet.length();
    }

    function getUsers(
        uint256 from,
        uint256 to
    ) public view onlyOwner returns (address[] memory) {
        uint256 userLength = userSet.length();

        if (from >= userLength || to <= from) {
            return new address[](0);
        }

        if (to > userLength) {
            to = userLength;
        }

        uint256 length = to - from;

        address[] memory retUsers = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            retUsers[i] = userSet.at(from + i);
        }

        return retUsers;
    }

    function previewAccruedReward() public view returns (uint256) {
        uint256 scheduledReward = _previewScheduledReward();

        uint256 backing = _availableLiquidity();

        if (backing <= accountedAssets) {
            return 0;
        }

        uint256 availableRewardBacking = backing - accountedAssets;

        return Math.min(scheduledReward, availableRewardBacking);
    }

    /// @dev Includes rewards accrued since the last settlement so ERC4626 previews use the latest share value.
    function totalAssets() public view override returns (uint256) {
        return accountedAssets + previewAccruedReward();
    }

    function rewardFundingStatus()
        external
        view
        returns (uint256 shortfall, bool sufficient)
    {
        uint256 actualBalance = _availableLiquidity();
        uint256 requiredBalance = accountedAssets + _previewScheduledReward();

        if (actualBalance >= requiredBalance) {
            sufficient = true;
            shortfall = 0;
        } else {
            sufficient = false;
            shortfall = requiredBalance - actualBalance;
        }
    }

    /// @notice Adds reward backing without immediately increasing the value of outstanding shares.
    function fundRewards(uint256 amount) external {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        emit RewardsFunded(msg.sender, amount);
    }

    function availableExcessRewards() public view returns (uint256) {
        uint256 totalBacking = _availableLiquidity();

        uint256 requiredBacking = accountedAssets + previewAccruedReward();

        if (totalBacking <= requiredBacking) {
            return 0;
        }

        return totalBacking - requiredBacking;
    }

    function accrue() external onlyOwner nonReentrant returns (uint256) {
        return _accrueRewards();
    }

    /// @inheritdoc ERC4626
    function maxDeposit(
        address receiver
    ) public view override returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxDeposit(receiver);
    }

    /// @inheritdoc ERC4626
    function maxMint(address receiver) public view override returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxMint(receiver);
    }

    /// @inheritdoc ERC4626
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused()) {
            return 0;
        }
        uint256 ownerAssets = previewRedeem(balanceOf(owner));
        uint256 availableLiquidity = _availableLiquidity();

        return Math.min(ownerAssets, availableLiquidity);
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused()) {
            return 0;
        }
        uint256 ownerShares = super.maxRedeem(owner);
        uint256 availableShares = convertToShares(_availableLiquidity());

        return Math.min(ownerShares, availableShares);
    }

    /// @inheritdoc ERC4626
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets == 0) {
            return 0;
        }

        _accrueRewards();

        shares = super.deposit(assets, receiver);

        accountedAssets += assets;

        _deployToStrategy(assets);

        userSet.add(msg.sender);
    }

    /// @inheritdoc ERC4626
    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) {
            return 0;
        }

        _accrueRewards();

        assets = super.mint(shares, receiver);

        accountedAssets += assets;

        _deployToStrategy(assets);

        userSet.add(msg.sender);
    }

    /// @inheritdoc ERC4626
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets == 0) {
            return 0;
        }

        _accrueRewards();

        _ensureLiquidity(assets);

        shares = super.withdraw(assets, receiver, owner);

        accountedAssets -= assets;
    }

    /// @inheritdoc ERC4626
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) {
            return 0;
        }

        _accrueRewards();

        assets = previewRedeem(shares);

        _ensureLiquidity(assets);

        super.redeem(shares, receiver, owner);

        accountedAssets -= assets;
    }

    function setStrategyWithdrawTolerance(
        uint256 tolerance
    ) external onlyOwner {
        uint256 oldTolerance = withdrawTolerance;
        withdrawTolerance = tolerance;
        emit WithdrawToleranceChanged(oldTolerance, tolerance);
    }

    function setStrategy(
        IHiveStrategy _hiveStrategy,
        uint256 _withdrawTolerance
    ) external onlyOwner nonReentrant {
        if (
            address(_hiveStrategy) != address(0) &&
            (_hiveStrategy.asset() != asset() ||
                _hiveStrategy.market() != address(this))
        ) {
            revert WrongStrategy();
        }

        IHiveStrategy oldStrategy = hiveStrategy;

        // Fully unwind the previous strategy before granting approval to the replacement.
        if (address(oldStrategy) != address(0)) {
            uint256 principal = oldStrategy.principal();
            if (principal > 0) {
                oldStrategy.withdrawAll();
            }
            IERC20(asset()).forceApprove(address(oldStrategy), 0);
        }

        hiveStrategy = _hiveStrategy;

        if (address(hiveStrategy) != address(0)) {
            IERC20(asset()).forceApprove(
                address(hiveStrategy),
                type(uint256).max
            );
            hiveStrategy.deposit(accountedAssets);
        }

        emit ChangeStrategy(address(oldStrategy), address(hiveStrategy));

        uint256 oldTolerance = withdrawTolerance;
        withdrawTolerance = _withdrawTolerance;

        emit WithdrawToleranceChanged(oldTolerance, _withdrawTolerance);
    }

    function setApyBps(uint256 _apyBps) external onlyOwner nonReentrant {
        if (_apyBps > maxApyBps) {
            revert ApyBpsExceedsMaximum(_apyBps, maxApyBps);
        }

        _accrueRewards();

        uint256 _oldBps = apyBps;
        apyBps = _apyBps;
        emit ApyBpsChanged(_oldBps, _apyBps);
    }

    function setMaxApyBps(uint256 _maxApyBps) external onlyOwner {
        if (_maxApyBps < apyBps) {
            revert MaxApyBpsBelowCurrentApy(_maxApyBps, apyBps);
        }

        uint256 oldMaxApyBps = maxApyBps;
        maxApyBps = _maxApyBps;

        emit MaxApyBpsChanged(oldMaxApyBps, _maxApyBps);
    }

    function rescueToken(
        IERC20 token,
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (address(token) == address(0) || to == address(0)) {
            revert ZeroAddress();
        }

        if (address(token) == asset()) {
            revert CannotRescueAsset();
        }

        token.safeTransfer(to, amount);

        emit TokenRescued(address(token), to, amount);
    }

    /// @notice Withdraws only backing that is not required for principal or accrued rewards.
    function withdrawExcessRewards(
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (to == address(0)) {
            revert ZeroAddress();
        }

        uint256 excess = availableExcessRewards();

        if (amount > excess) {
            amount = excess;
        }

        IERC20(asset()).safeTransfer(to, amount);

        emit ExcessRewardsWithdrawn(to, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _accrueRewards() internal returns (uint256) {
        uint256 reward = previewAccruedReward();

        lastAccrualTime = block.timestamp;
        if (reward == 0) {
            return 0;
        }

        _deployToStrategy(reward);

        accountedAssets += reward;
        totalRewardsAccrued += reward;

        uint256 supply = totalSupply();
        accRewardPerShare += Math.mulDiv(reward, REWARD_PRECISION, supply);

        emit RewardsAccrued(reward, totalRewardsAccrued, accRewardPerShare);

        return reward;
    }

    function _deployToStrategy(uint256 assets) internal {
        if (address(hiveStrategy) != address(0)) {
            hiveStrategy.deposit(assets);
        }
    }

    function _ensureLiquidity(uint256 assets) internal {
        IERC20 token = IERC20(asset());
        uint256 balanceBefore = token.balanceOf(address(this));

        if (address(hiveStrategy) == address(0)) {
            if (balanceBefore < assets) {
                revert InsufficientLiquidity();
            }
            return;
        }

        hiveStrategy.withdraw(assets);

        uint256 balanceAfter = token.balanceOf(address(this));

        uint256 received = balanceAfter - balanceBefore;

        if (received < assets && assets - received > withdrawTolerance) {
            revert InsufficientLiquidity();
        }

        if (balanceAfter < assets) {
            revert InsufficientLiquidity();
        }
    }

    function _availableLiquidity() internal view returns (uint256 liquidity) {
        liquidity = IERC20(asset()).balanceOf(address(this));

        if (address(hiveStrategy) != address(0)) {
            liquidity += hiveStrategy.principal();
        }
    }

    function _previewScheduledReward() internal view returns (uint256) {
        if (accountedAssets == 0 || totalSupply() == 0 || apyBps == 0) {
            return 0;
        }

        if (lastAccrualTime >= block.timestamp) {
            return 0;
        }

        uint256 elapsed = block.timestamp - lastAccrualTime;

        // Rewards accrue linearly between settlements using the configured annual rate.
        return Math.mulDiv(accountedAssets, apyBps * elapsed, BPS * YEAR);
    }
}
