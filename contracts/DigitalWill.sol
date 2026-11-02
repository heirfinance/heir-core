// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DigitalWill
/// @notice Accepts ETH deposits as a "will", locking them until one of two conditions:
///         1) the testator-chosen lock period expires (1 month / 1 year / 5 years);
///         2) the testator has not called checkIn() for longer than CHECK_IN_INTERVAL (30 days) — dead man's switch.
///         When conditions are met, anyone can call release(): funds are credited to heirs by share
///         (or back to the testator if no heirs were set) into the claimable mapping,
///         from which each recipient withdraws their own share via claim() — pull model, not push,
///         so a single malicious heir cannot block payouts to the rest.
///         While the will is active, the testator may deposit, update heirs,
///         partially or fully withdraw, and reset the inactivity timer via checkIn().
contract DigitalWill {
    enum LockPeriod {
        OneMonth,
        OneYear,
        FiveYears
    }

    struct Heir {
        address addr;
        uint16 shareBps; // share in basis points, 10000 = 100%
    }

    struct Will {
        address testator;
        uint256 balance;
        uint256 createdAt;
        uint256 unlockTime;
        uint256 lastCheckIn;
        Heir[] heirs;
    }

    uint256 public constant CHECK_IN_INTERVAL = 30 days;
    uint256 public constant TOTAL_BPS = 10000;
    uint256 public constant MAX_HEIRS = 20;
    uint16 public constant FEE_BPS = 100; // 1%

    /// @notice Recipient of the deposit fee taken by createWill() and deposit(). Fixed at
    ///         deployment; withdraw() and release() never touch it — only inbound deposits do.
    address public immutable feeCollector;

    mapping(address => Will) private wills;

    /// @notice Funds credited to an address from a released will, waiting to be withdrawn via
    ///         claim(). Pull-payment by design: release() only ever credits this mapping, never
    ///         pushes ETH directly to a heir. A single malicious/broken heir contract that
    ///         reverts on receiving ETH would otherwise be able to permanently block the entire
    ///         distribution (including to every other, honest heir) — exactly when the testator
    ///         is no longer around to fix it by cancelling and recreating the will.
    mapping(address => uint256) public claimable;

    bool private locked;

    modifier nonReentrant() {
        require(!locked, "reentrancy");
        locked = true;
        _;
        locked = false;
    }

    modifier onlyTestator() {
        require(wills[msg.sender].testator == msg.sender, "no active will");
        _;
    }

    event WillCreated(address indexed testator, uint256 amount, uint256 unlockTime);
    event Deposited(address indexed testator, uint256 amount, uint256 newBalance);
    event CheckedIn(address indexed testator, uint256 timestamp);
    event HeirsUpdated(address indexed testator);
    event Withdrawn(address indexed testator, uint256 amount, uint256 remainingBalance);
    event WillCancelled(address indexed testator, uint256 refunded);
    event Released(address indexed testator, address indexed triggeredBy, uint256 totalAmount, bool returnedToTestator);
    event Claimed(address indexed claimant, uint256 amount);

    constructor(address _feeCollector) {
        require(_feeCollector != address(0), "zero feeCollector address");
        feeCollector = _feeCollector;
    }

    /// @notice Create a will. Heirs array may be empty — in that case funds are returned
    ///         to the testator on release. FEE_BPS is deducted from msg.value and forwarded
    ///         to feeCollector immediately; the remainder is credited to the will balance.
    function createWill(Heir[] calldata heirs_, LockPeriod period) external payable nonReentrant {
        require(msg.value > 0, "no funds sent");
        require(wills[msg.sender].testator == address(0), "will already exists");
        _validateHeirs(heirs_);

        (uint256 fee, uint256 depositAmount) = _splitFee(msg.value);

        Will storage w = wills[msg.sender];
        w.testator = msg.sender;
        w.balance = depositAmount;
        w.createdAt = block.timestamp;
        w.unlockTime = block.timestamp + _durationOf(period);
        w.lastCheckIn = block.timestamp;
        for (uint256 i = 0; i < heirs_.length; i++) {
            w.heirs.push(heirs_[i]);
        }

        emit WillCreated(msg.sender, depositAmount, w.unlockTime);
        _sendFee(fee);
    }

    /// @notice Top up an existing will. Fee is deducted the same way as in createWill().
    ///         Depositing is an active owner action, so it resets the inactivity timer (lastCheckIn),
    ///         just like withdraw() and checkIn().
    function deposit() external payable nonReentrant onlyTestator {
        require(msg.value > 0, "no funds sent");
        (uint256 fee, uint256 depositAmount) = _splitFee(msg.value);

        Will storage w = wills[msg.sender];
        w.balance += depositAmount;
        // Depositing ETH is proof of activity — reset the dead man's switch timer.
        w.lastCheckIn = block.timestamp;
        emit Deposited(msg.sender, depositAmount, w.balance);
        _sendFee(fee);
    }

    /// @notice Proof-of-life check-in — resets the inactivity timer. Does not change unlockTime.
    function checkIn() external onlyTestator {
        wills[msg.sender].lastCheckIn = block.timestamp;
        emit CheckedIn(msg.sender, block.timestamp);
    }

    /// @notice Only the testator may set or update heirs.
    function setHeirs(Heir[] calldata heirs_) external onlyTestator {
        _validateHeirs(heirs_);
        Will storage w = wills[msg.sender];
        delete w.heirs;
        for (uint256 i = 0; i < heirs_.length; i++) {
            w.heirs.push(heirs_[i]);
        }
        emit HeirsUpdated(msg.sender);
    }

    /// @notice Partial withdrawal of own funds. Calling this resets the inactivity timer (proof of life).
    function withdraw(uint256 amount) external nonReentrant onlyTestator {
        Will storage w = wills[msg.sender];
        require(amount > 0 && amount <= w.balance, "invalid amount");
        w.balance -= amount;
        w.lastCheckIn = block.timestamp;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
        emit Withdrawn(msg.sender, amount, w.balance);
    }

    /// @notice Cancel the will entirely: remaining balance is returned to the testator and the record is deleted.
    function cancelWill() external nonReentrant onlyTestator {
        Will storage w = wills[msg.sender];
        uint256 amount = w.balance;
        delete wills[msg.sender];
        if (amount > 0) {
            (bool ok, ) = msg.sender.call{value: amount}("");
            require(ok, "transfer failed");
        }
        emit WillCancelled(msg.sender, amount);
    }

    /// @notice Whether release conditions are met: lock period expired OR inactivity interval exceeded.
    ///         OR is intentional: the dead man's switch unlocks funds after 30 days of inactivity
    ///         regardless of the chosen lock period. Changing to AND would break this core feature.
    function isReleasable(address testator) public view returns (bool) {
        Will storage w = wills[testator];
        if (w.testator == address(0)) return false;
        // Intentional OR: 30-day inactivity triggers release regardless of lock period (dead man's switch),
        // OR the chosen lock period has simply expired. Both are valid release conditions.
        return block.timestamp >= w.unlockTime || block.timestamp >= w.lastCheckIn + CHECK_IN_INTERVAL;
    }

    /// @notice Trigger payout. Anyone may call (heir, testator, keeper/bot) — recipients are
    ///         always determined by the will data, not the caller. Funds are never pushed directly;
    ///         they are credited to claimable[...] so each recipient pulls their own share via
    ///         claim(). This prevents a single malicious or broken heir address from blocking
    ///         the entire distribution.
    function release(address testator) external nonReentrant {
        Will storage w = wills[testator];
        require(w.testator != address(0), "no active will");
        require(isReleasable(testator), "conditions not met");

        uint256 amount = w.balance;
        Heir[] memory heirs_ = w.heirs;
        delete wills[testator];

        if (amount == 0) {
            emit Released(testator, msg.sender, 0, heirs_.length == 0);
            return;
        }

        if (heirs_.length == 0) {
            claimable[testator] += amount;
            emit Released(testator, msg.sender, amount, true);
            return;
        }

        uint256 distributed = 0;
        for (uint256 i = 0; i < heirs_.length; i++) {
            uint256 share = (i == heirs_.length - 1)
                ? amount - distributed // last heir gets the remainder to avoid rounding dust
                : (amount * heirs_[i].shareBps) / TOTAL_BPS;
            distributed += share;
            if (share > 0) {
                claimable[heirs_[i].addr] += share;
            }
        }
        emit Released(testator, msg.sender, amount, false);
    }

    /// @notice Withdraw funds credited to the caller by release() — either as an heir or as
    ///         the testator if no heirs were set.
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        require(amount > 0, "nothing to claim");
        claimable[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
        emit Claimed(msg.sender, amount);
    }

    /// @notice Returns full will data for the frontend.
    function getWill(address testator)
        external
        view
        returns (
            uint256 balance,
            uint256 createdAt,
            uint256 unlockTime,
            uint256 lastCheckIn,
            uint256 checkInDeadline,
            bool releasable,
            Heir[] memory heirs_
        )
    {
        Will storage w = wills[testator];
        return (
            w.balance,
            w.createdAt,
            w.unlockTime,
            w.lastCheckIn,
            w.lastCheckIn + CHECK_IN_INTERVAL,
            isReleasable(testator),
            w.heirs
        );
    }

    /// @notice Splits an incoming deposit into (fee, depositAmount) per FEE_BPS.
    function _splitFee(uint256 amount) internal pure returns (uint256 fee, uint256 depositAmount) {
        fee = (amount * FEE_BPS) / TOTAL_BPS;
        depositAmount = amount - fee;
    }

    /// @notice Forwards the fee portion to feeCollector. Reverts the whole tx on failure.
    function _sendFee(uint256 fee) internal {
        if (fee == 0) return;
        (bool ok, ) = feeCollector.call{value: fee}("");
        require(ok, "fee transfer failed");
    }

    function _durationOf(LockPeriod period) internal pure returns (uint256) {
        if (period == LockPeriod.OneMonth) return 30 days;
        if (period == LockPeriod.OneYear) return 365 days;
        return 5 * 365 days; // FiveYears
    }

    function _validateHeirs(Heir[] calldata heirs_) internal pure {
        require(heirs_.length <= MAX_HEIRS, "too many heirs");
        if (heirs_.length == 0) return;
        uint256 sum = 0;
        for (uint256 i = 0; i < heirs_.length; i++) {
            require(heirs_[i].addr != address(0), "zero heir address");
            require(heirs_[i].shareBps > 0, "zero heir share");
            for (uint256 j = i + 1; j < heirs_.length; j++) {
                require(heirs_[i].addr != heirs_[j].addr, "duplicate heir address");
            }
            sum += heirs_[i].shareBps;
        }
        require(sum == TOTAL_BPS, "shares must sum to 10000");
    }
}
