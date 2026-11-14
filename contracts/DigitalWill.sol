// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Digital Will — dead man's switch for native coins and ERC-20 tokens
/// @author heir.finance
/// @notice Keeps a testator's native coins and ERC-20 tokens for their heirs. Until the will is
///         released, the testator can deposit, change heirs, withdraw any amount or cancel the will.
///         The will has one trigger: it becomes releasable once the testator has been inactive for
///         the inactivity period they chose (3 months / 6 months / 1 year). Every testator action
///         (check-in, deposit, withdrawal, changing heirs or the period) resets that timer, so a
///         testator who stays active keeps the will forever.
///         Once releasable, anyone can call release(), which is final: it credits the heirs by share,
///         or the testator if no heirs were set. Each recipient then collects their own credit.
///         Until someone calls release(), the testator can still check in or cancel.
/// @dev    Architecture:
///         - Not upgradeable: fixing a bug requires deploying a new contract.
///         - The owner can only pause new deposits and transfer or renounce ownership (inherited from
///           Ownable). The owner cannot move user funds and cannot block withdrawals, check-ins,
///           cancellation, release or claims. Renouncing while paused leaves deposits paused forever.
///         - Pull payments: release() makes no external calls and only updates credits, so a broken
///           recipient or token cannot block a payout to anyone else.
///         - A 1% fee (FEE_BPS) is charged on deposits only. Native coin fees accrue in pendingFees;
///           token fees are sent to feeCollector during the deposit.
///         - "ETH" in names and comments means the native coin of the chain this contract is deployed
///           on (ETH, POL, BNB, ...).
contract DigitalWill is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Inactivity periods a testator can choose. The will becomes releasable after this much
    ///         time without testator activity.
    enum InactivityPeriod {
        ThreeMonths, // 90 days
        SixMonths,   // 180 days
        OneYear      // 365 days
    }

    /// @notice An heir and their share of the will.
    struct Heir {
        address addr;
        uint16 shareBps; // share in basis points, 10000 = 100%
    }

    /// @notice An ERC-20 token and amount to deposit when creating a will.
    struct TokenDeposit {
        address token;
        uint256 amount;
    }

    /// @notice State of one testator's will. Token balances are kept in tokenBalances.
    struct Will {
        address testator;
        uint256 balance;           // ETH balance, net of fee
        uint256 createdAt;
        uint256 inactivityPeriod;  // seconds of inactivity after which the will is releasable
        uint256 lastCheckIn;       // timestamp of the last testator activity
        Heir[] heirs;
        address[] depositedTokens; // ERC-20 tokens ever deposited into this will, see MAX_TOKENS
    }

    /// @notice Basis points that make up 100%; heir shares must add up to this value.
    uint256 public constant TOTAL_BPS = 10000;
    /// @notice Maximum number of heirs per will.
    uint256 public constant MAX_HEIRS = 20;
    /// @notice Deposit fee in basis points (100 = 1%).
    uint16 public constant FEE_BPS = 100; // 1%
    /// @notice Maximum number of different tokens deposited during the lifetime of one will.
    uint8 public constant MAX_TOKENS = 10;

    /// @notice Maximum balance of one token in one will.
    /// @dev    Keeps amount * shareBps in _distributeToken() far from overflow, so no token amount can
    ///         make release() revert.
    uint256 public constant MAX_TOKEN_BALANCE = type(uint128).max;

    /// @notice Recipient of deposit fees, fixed at deployment.
    /// @dev    Token fees are sent here by createWill() and depositToken(). Native coin fees accrue in
    ///         pendingFees until withdrawFees() is called. Withdrawals and release() never charge a fee.
    address public immutable feeCollector;

    /// @dev Active wills by testator. A will is deleted when it is cancelled or released.
    mapping(address => Will) private wills;

    /// @notice Native coins credited to an address and waiting to be collected via claim(), claimTo()
    ///         or claimFor().
    /// @dev    Credited by release(), and by cancelWill() when the direct refund fails.
    mapping(address => uint256) public claimable;

    // ---- ERC-20 token support ----

    /// @notice Token balances of active wills, net of fee: testator => token => amount.
    mapping(address => mapping(address => uint256)) public tokenBalances;

    /// @notice Tokens credited to an address and waiting to be collected via claimToken() or
    ///         claimTokenFor(): recipient => token => amount.
    /// @dev    Credited by release(), and by cancelWill() when the direct refund fails.
    mapping(address => mapping(address => uint256)) public claimableTokens;

    /// @notice Total balance of each token across all active wills.
    mapping(address => uint256) public totalWillTokenBalances;

    /// @notice Total credited and not yet collected amount of each token.
    mapping(address => uint256) public totalClaimableTokens;

    /// @notice Whether new deposits and new wills are paused.
    /// @dev    Only createWill(), deposit() and depositToken() check this flag.
    bool public paused;

    /// @notice Native coin fees accrued and waiting to be sent to feeCollector via withdrawFees().
    /// @dev    These are not user funds. Accruing them means a broken feeCollector cannot block deposits.
    uint256 public pendingFees;

    /// @dev Whether a token is already listed in the testator's current will (avoids an O(n) array
    ///      search). Must be cleared manually when a will ends, because `delete wills[testator]` does
    ///      not clear nested mappings.
    mapping(address => mapping(address => bool)) private _tokenRegistered;

    // ---- Modifiers ----

    /// @dev Restricts a function to the caller's own active will.
    modifier onlyTestator() {
        require(wills[msg.sender].testator == msg.sender, "no active will");
        _;
    }

    /// @dev Blocks a function while new deposits are paused.
    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    // ---- Events ----

    /// @notice Emitted when a will is created.
    /// @param testator Creator of the will.
    /// @param amount Native coins deposited, net of fee.
    /// @param inactivityPeriod Seconds of inactivity after which the will becomes releasable.
    event WillCreated(address indexed testator, uint256 amount, uint256 inactivityPeriod);
    /// @notice Emitted when native coins are added to a will.
    /// @param testator Owner of the will.
    /// @param amount Amount added, net of fee.
    /// @param newBalance Native coin balance of the will after the deposit.
    event Deposited(address indexed testator, uint256 amount, uint256 newBalance);
    /// @notice Emitted when a testator checks in.
    /// @param testator Owner of the will.
    /// @param timestamp Time of the check-in.
    event CheckedIn(address indexed testator, uint256 timestamp);
    /// @notice Emitted when a testator replaces the list of heirs.
    /// @param testator Owner of the will.
    event HeirsUpdated(address indexed testator);
    /// @notice Emitted when a testator changes the inactivity period.
    /// @param testator Owner of the will.
    /// @param inactivityPeriod New period in seconds.
    event InactivityPeriodChanged(address indexed testator, uint256 inactivityPeriod);
    /// @notice Emitted when native coins are withdrawn from a will.
    /// @param testator Owner of the will.
    /// @param amount Amount withdrawn.
    /// @param remainingBalance Native coin balance left in the will.
    event Withdrawn(address indexed testator, uint256 amount, uint256 remainingBalance);
    /// @notice Emitted when a will is cancelled.
    /// @param testator Former owner of the will.
    /// @param refunded Native coin balance of the will at cancellation, whether sent or credited.
    event WillCancelled(address indexed testator, uint256 refunded);
    /// @notice Emitted when a will is released.
    /// @param testator Former owner of the will.
    /// @param triggeredBy Address that called release().
    /// @param totalAmount Native coins credited to recipients.
    /// @param returnedToTestator True if the will had no heirs and was credited to the testator.
    event Released(address indexed testator, address indexed triggeredBy, uint256 totalAmount, bool returnedToTestator);
    /// @notice Emitted when credited native coins are collected.
    /// @param claimant Address whose credit was collected.
    /// @param amount Amount collected.
    event Claimed(address indexed claimant, uint256 amount);

    /// @notice Emitted when tokens are added to a will.
    /// @param testator Owner of the will.
    /// @param token Token deposited.
    /// @param amount Amount added, net of fee.
    /// @param fee Fee sent to feeCollector.
    /// @param newBalance Token balance of the will after the deposit.
    event TokenDeposited(address indexed testator, address indexed token, uint256 amount, uint256 fee, uint256 newBalance);
    /// @notice Emitted when tokens are withdrawn from a will.
    /// @param testator Owner of the will.
    /// @param token Token withdrawn.
    /// @param amount Amount withdrawn.
    /// @param remainingBalance Token balance left in the will.
    event TokenWithdrawn(address indexed testator, address indexed token, uint256 amount, uint256 remainingBalance);
    /// @notice Emitted when a token deposit fee is sent to feeCollector.
    /// @param from Depositor.
    /// @param token Token of the fee.
    /// @param fee Fee amount.
    event TokenFeePaid(address indexed from, address indexed token, uint256 fee);
    /// @notice Emitted when credited tokens are collected.
    /// @param claimant Address whose credit was collected.
    /// @param token Token collected.
    /// @param amount Amount collected.
    event TokenClaimed(address indexed claimant, address indexed token, uint256 amount);
    /// @notice Emitted for each token credited to recipients by release().
    /// @param testator Former owner of the will.
    /// @param token Token released.
    /// @param totalAmount Amount credited.
    event TokenReleased(address indexed testator, address indexed token, uint256 totalAmount);
    /// @notice Emitted when new deposits are paused.
    /// @param by Account that paused.
    event Paused(address indexed by);
    /// @notice Emitted when new deposits are resumed.
    /// @param by Account that resumed.
    event Unpaused(address indexed by);
    /// @notice Emitted when accrued native coin fees are sent to feeCollector.
    /// @param to Fee recipient.
    /// @param amount Amount sent.
    event FeesWithdrawn(address indexed to, uint256 amount);

    /// @notice Emitted in addition to Withdrawn or Claimed when native coins go to an address other
    ///         than the account they were debited from.
    /// @param from Account debited.
    /// @param to Address paid.
    /// @param amount Amount paid.
    event PayoutRedirected(address indexed from, address indexed to, uint256 amount);

    // ---- Constructor ----

    /// @param _feeCollector Permanent recipient of deposit fees.
    /// @param initialOwner_ Account allowed to pause and resume new deposits.
    constructor(address _feeCollector, address initialOwner_) Ownable(initialOwner_) {
        require(_feeCollector != address(0), "zero feeCollector");
        feeCollector = _feeCollector;
    }

    // ---- Owner-only admin functions ----

    /// @notice Stops new deposits and new wills. Withdrawals, check-ins, heir changes, cancellation,
    ///         release and claims keep working.
    function pause() external onlyOwner {
        require(!paused, "already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resumes new deposits and new wills.
    function unpause() external onlyOwner {
        require(paused, "not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Sends all accrued native coin fees to feeCollector. Callable by anyone.
    /// @dev    Fee collection is separate from deposits, so a broken feeCollector only blocks this call.
    function withdrawFees() external nonReentrant {
        uint256 amount = pendingFees;
        require(amount > 0, "no fees");
        pendingFees = 0;
        (bool ok, ) = feeCollector.call{value: amount}("");
        require(ok, "fee transfer failed");
        emit FeesWithdrawn(feeCollector, amount);
    }

    // ---- Core ETH will functions ----

    /// @notice Creates a will with native coins and/or ERC-20 tokens in one transaction.
    ///         A FEE_BPS fee is deducted from every asset deposited. Tokens must be approved first.
    /// @dev    REBASING and UNTRUSTED tokens: see depositToken().
    /// @param heirs_ Heirs and their shares. May be empty: the will is then credited to the testator on
    ///        release. Otherwise shares must add up to TOTAL_BPS.
    /// @param period Inactivity period: the will becomes releasable after this long without testator
    ///        activity.
    /// @param tokens_ Tokens and amounts to deposit, at most MAX_TOKENS.
    function createWill(Heir[] calldata heirs_, InactivityPeriod period, TokenDeposit[] calldata tokens_) external payable nonReentrant whenNotPaused {
        require(msg.value > 0 || tokens_.length > 0, "no funds sent");
        require(wills[msg.sender].testator == address(0), "will already exists");
        require(tokens_.length <= MAX_TOKENS, "too many tokens");
        _validateHeirs(heirs_);

        (uint256 fee, uint256 depositAmount) = _splitFee(msg.value);

        Will storage w = wills[msg.sender];
        w.testator = msg.sender;
        w.balance = depositAmount;
        w.createdAt = block.timestamp;
        w.inactivityPeriod = _durationOf(period);
        w.lastCheckIn = block.timestamp;
        for (uint256 i = 0; i < heirs_.length; i++) {
            w.heirs.push(heirs_[i]);
        }

        emit WillCreated(msg.sender, depositAmount, w.inactivityPeriod);
        if (fee > 0) _accrueFee(fee);

        // Deposit each token
        for (uint256 i = 0; i < tokens_.length; i++) {
            address token = tokens_[i].token;
            uint256 amount = tokens_[i].amount;
            require(token != address(0), "zero token address");
            require(token.code.length > 0, "not a contract");
            require(amount > 0, "zero token amount");

            if (!_tokenRegistered[msg.sender][token]) {
                w.depositedTokens.push(token);
                _tokenRegistered[msg.sender][token] = true;
            }

            uint256 balanceBefore = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
            require(received == amount, "fee-on-transfer not supported");

            (uint256 tokenFee, uint256 net) = _splitFee(amount);
            if (tokenFee > 0) {
                IERC20(token).safeTransfer(feeCollector, tokenFee);
                emit TokenFeePaid(msg.sender, token, tokenFee);
            }

            tokenBalances[msg.sender][token] += net;
            require(tokenBalances[msg.sender][token] <= MAX_TOKEN_BALANCE, "token balance too large");
            totalWillTokenBalances[token] += net;
            emit TokenDeposited(msg.sender, token, net, tokenFee, tokenBalances[msg.sender][token]);
        }
    }

    /// @notice Adds the sent native coins to the caller's will, minus the FEE_BPS fee.
    ///         Resets the inactivity timer.
    function deposit() external payable nonReentrant onlyTestator whenNotPaused {
        require(msg.value > 0, "no funds sent");
        (uint256 fee, uint256 depositAmount) = _splitFee(msg.value);

        Will storage w = wills[msg.sender];
        w.balance += depositAmount;
        w.lastCheckIn = block.timestamp;
        emit Deposited(msg.sender, depositAmount, w.balance);
        _accrueFee(fee);
    }

    /// @notice Proof of life: resets the inactivity timer. Works even after the will has become
    ///         releasable, as long as nobody has called release() yet: the will is then no longer
    ///         releasable.
    function checkIn() external onlyTestator {
        wills[msg.sender].lastCheckIn = block.timestamp;
        emit CheckedIn(msg.sender, block.timestamp);
    }

    /// @notice Replaces the caller's list of heirs. Resets the inactivity timer.
    /// @param heirs_ New heirs and shares. May be empty: the will is then credited to the testator on
    ///        release. Otherwise shares must add up to TOTAL_BPS.
    function setHeirs(Heir[] calldata heirs_) external onlyTestator {
        _validateHeirs(heirs_);
        Will storage w = wills[msg.sender];
        delete w.heirs;
        for (uint256 i = 0; i < heirs_.length; i++) {
            w.heirs.push(heirs_[i]);
        }
        w.lastCheckIn = block.timestamp;
        emit HeirsUpdated(msg.sender);
    }

    /// @notice Changes the caller's inactivity period. Resets the inactivity timer, so the new period
    ///         is counted from now.
    /// @param period New inactivity period.
    function setInactivityPeriod(InactivityPeriod period) external onlyTestator {
        Will storage w = wills[msg.sender];
        w.inactivityPeriod = _durationOf(period);
        w.lastCheckIn = block.timestamp;
        emit InactivityPeriodChanged(msg.sender, w.inactivityPeriod);
    }

    /// @notice Withdraws native coins from the caller's will, up to its full balance, without a fee.
    ///         The will stays active even if empty. Resets the inactivity timer.
    /// @param amount Amount to withdraw.
    function withdraw(uint256 amount) external nonReentrant onlyTestator {
        _withdrawNative(msg.sender, amount);
    }

    /// @notice Same as withdraw(), but pays `to`. For contract wallets that cannot receive native coins.
    /// @param to Address to pay. Cannot be the zero address or this contract.
    /// @param amount Amount to withdraw.
    function withdrawTo(address to, uint256 amount) external nonReentrant onlyTestator {
        _requireValidRecipient(to);
        _withdrawNative(to, amount);
    }

    /// @notice Cancels the caller's will and returns its full balance without a fee.
    ///         Native coins and tokens are sent back immediately. Anything that cannot be sent, for
    ///         example a paused or blacklisted token, is credited for later collection instead of
    ///         blocking the rest.
    /// @dev    The will is deleted before any transfer and the function is nonReentrant. Each token uses
    ///         SafeERC20.trySafeTransfer, so a token that returns no value (USDT) works and a malformed
    ///         response counts as a failed transfer. A token that burns all forwarded gas can still make
    ///         the call run out of gas at a low gas limit; other assets remain withdrawable separately.
    function cancelWill() external nonReentrant onlyTestator {
        Will storage w = wills[msg.sender];
        uint256 ethAmount = w.balance;

        // Copy token data BEFORE delete — Solidity delete does not clear nested mappings.
        address[] memory tokens = w.depositedTokens;
        uint256[] memory amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = tokenBalances[msg.sender][tokens[i]];
            tokenBalances[msg.sender][tokens[i]] = 0;
            totalWillTokenBalances[tokens[i]] -= amounts[i];
            // Clear registration so a future will can re-register this token.
            _tokenRegistered[msg.sender][tokens[i]] = false;
        }

        delete wills[msg.sender];

        // Push ETH directly back to testator — state is fully deleted before any
        // external call so reentrancy has no effect. If the push fails (e.g. the
        // testator is a contract that rejects native coins or tries to reenter),
        // fall back to the pull model: the testator collects via claim() or claimTo().
        if (ethAmount > 0) {
            (bool ok, ) = msg.sender.call{value: ethAmount}("");
            if (!ok) {
                claimable[msg.sender] += ethAmount;
            }
        }

        // Push each ERC-20 token directly. trySafeTransfer accepts tokens that return
        // no value (USDT) and reports any other failure (paused, blacklisted, malformed
        // return data, no code) as false, so one broken token falls back to the pull
        // model and does not block the return of ETH or other tokens.
        for (uint256 i = 0; i < tokens.length; i++) {
            if (amounts[i] == 0) continue;
            if (!IERC20(tokens[i]).trySafeTransfer(msg.sender, amounts[i])) {
                claimableTokens[msg.sender][tokens[i]] += amounts[i];
                totalClaimableTokens[tokens[i]] += amounts[i];
            }
        }

        emit WillCancelled(msg.sender, ethAmount);
    }

    /// @notice Whether the will can be released now: it exists and the testator has been inactive for
    ///         at least its inactivity period. Any testator action makes it non-releasable again until
    ///         the period passes once more.
    /// @param testator Owner of the will.
    /// @return True if the will exists and its inactivity period has passed.
    function isReleasable(address testator) public view returns (bool) {
        Will storage w = wills[testator];
        if (w.testator == address(0)) return false;
        return block.timestamp >= w.lastCheckIn + w.inactivityPeriod;
    }

    /// @notice Releases a releasable will. Callable by anyone and irreversible: the will is deleted and
    ///         its funds are credited to the heirs by share, or to the testator if there are no heirs.
    /// @dev    Makes no external calls, so neither a token nor a recipient can block it.
    /// @param testator Owner of the will to release.
    function release(address testator) external nonReentrant {
        Will storage w = wills[testator];
        require(w.testator != address(0), "no active will");
        require(isReleasable(testator), "conditions not met");

        uint256 ethAmount = w.balance;
        Heir[] memory heirs_ = w.heirs;
        address[] memory tokens = w.depositedTokens;

        // Copy token balances BEFORE delete — clearing nested mappings manually.
        uint256[] memory tokenAmounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenAmounts[i] = tokenBalances[testator][tokens[i]];
            tokenBalances[testator][tokens[i]] = 0;
            totalWillTokenBalances[tokens[i]] -= tokenAmounts[i];
            _tokenRegistered[testator][tokens[i]] = false;
        }

        delete wills[testator];

        // Distribute ETH
        if (ethAmount > 0) {
            _distributeNative(testator, ethAmount, heirs_);
        }

        // Distribute each token (pure accounting, no external calls)
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokenAmounts[i] > 0) {
                _distributeToken(testator, tokens[i], tokenAmounts[i], heirs_);
                emit TokenReleased(testator, tokens[i], tokenAmounts[i]);
            }
        }

        emit Released(testator, msg.sender, ethAmount, heirs_.length == 0);
    }

    /// @notice Collects the native coins credited to the caller, sending them to the caller.
    function claim() external nonReentrant {
        _claimNative(msg.sender, msg.sender);
    }

    /// @notice Collects the native coins credited to the caller and sends them to `to`. For contract
    ///         wallets that cannot receive native coins.
    /// @param to Address to pay. Cannot be the zero address or this contract.
    function claimTo(address to) external nonReentrant {
        _requireValidRecipient(to);
        _claimNative(msg.sender, to);
    }

    /// @notice Pays the native coins credited to `recipient` to that same address. Callable by anyone:
    ///         the funds can only reach `recipient`. For heirs that can receive funds but cannot send a
    ///         transaction, such as exchange deposit addresses.
    /// @param recipient Address whose credit is paid out.
    function claimFor(address recipient) external nonReentrant {
        _claimNative(recipient, recipient);
    }

    // ---- ERC-20 token functions ----

    /// @notice Adds ERC-20 tokens to the caller's will, minus the FEE_BPS fee. Tokens must be approved
    ///         first. Resets the inactivity timer.
    ///         Fee-on-transfer tokens are rejected. A will can receive at most MAX_TOKENS different
    ///         tokens during its lifetime: a slot stays used even after the token is fully withdrawn.
    /// @dev    REBASING TOKENS NOT SUPPORTED: tokens whose balances change automatically (stETH, aUSDC,
    ///         etc.) can leave the contract holding less than it owes. Wills share one balance per token,
    ///         so a shortfall affects every recipient of that token: late collectors may be unable to
    ///         collect in full.
    ///         UNTRUSTED TOKENS: a malicious token may never transfer, so heirs may be unable to collect
    ///         it. Its failure does not affect release(), native coins or other tokens, except that a
    ///         gas-burning token can make cancelWill() run out of gas (see there). Only deposit known,
    ///         audited tokens (USDC, USDT, WETH, etc.).
    /// @param token Token to deposit.
    /// @param amount Amount to transfer from the caller, before the fee.
    function depositToken(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(token != address(0), "zero address");
        require(token.code.length > 0, "not a contract");
        require(amount > 0, "zero amount");
        Will storage w = wills[msg.sender];
        require(w.testator == msg.sender, "no active will");

        // If this token hasn't been registered for this will yet, claim a slot.
        if (!_tokenRegistered[msg.sender][token]) {
            require(w.depositedTokens.length < MAX_TOKENS, "too many tokens");
            w.depositedTokens.push(token);
            _tokenRegistered[msg.sender][token] = true;
        }

        // Fee-on-transfer protection: measure actual received amount.
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        require(received == amount, "fee-on-transfer not supported");

        (uint256 fee, uint256 net) = _splitFee(amount);

        if (fee > 0) {
            IERC20(token).safeTransfer(feeCollector, fee);
            emit TokenFeePaid(msg.sender, token, fee);
        }

        tokenBalances[msg.sender][token] += net;
        require(tokenBalances[msg.sender][token] <= MAX_TOKEN_BALANCE, "token balance too large");
        totalWillTokenBalances[token] += net;
        w.lastCheckIn = block.timestamp;

        emit TokenDeposited(msg.sender, token, net, fee, tokenBalances[msg.sender][token]);
    }

    /// @notice Withdraws tokens from the caller's will to the caller, without a fee.
    ///         Resets the inactivity timer.
    /// @param token Token to withdraw.
    /// @param amount Amount to withdraw.
    function withdrawToken(address token, uint256 amount) external nonReentrant onlyTestator {
        require(amount > 0, "zero amount");
        require(tokenBalances[msg.sender][token] >= amount, "insufficient balance");

        tokenBalances[msg.sender][token] -= amount;
        totalWillTokenBalances[token] -= amount;
        wills[msg.sender].lastCheckIn = block.timestamp;

        IERC20(token).safeTransfer(msg.sender, amount);
        emit TokenWithdrawn(msg.sender, token, amount, tokenBalances[msg.sender][token]);
    }

    /// @notice Collects the full credited amount of a token, sending it to the caller.
    /// @param token Token to collect.
    function claimToken(address token) external nonReentrant {
        _claimToken(token, msg.sender);
    }

    /// @notice Pays the tokens credited to `recipient` to that same address. Callable by anyone: the
    ///         tokens can only reach `recipient`. See claimFor().
    /// @param token Token to pay out.
    /// @param recipient Address whose credit is paid out.
    function claimTokenFor(address token, address recipient) external nonReentrant {
        _claimToken(token, recipient);
    }

    // ---- View functions ----

    /// @notice Returns a will's native coin balance, timing and heirs. All values are zero or empty if
    ///         the will does not exist.
    /// @param testator Owner of the will.
    /// @return balance Native coin balance.
    /// @return createdAt Creation timestamp.
    /// @return inactivityPeriod Seconds of inactivity after which the will becomes releasable.
    /// @return lastCheckIn Timestamp of the last testator activity.
    /// @return releasableAt Timestamp from which the will can be released, unless the testator acts
    ///         before then.
    /// @return releasable Whether the will can be released now.
    /// @return heirs_ Heirs and their shares.
    function getWill(address testator)
        external
        view
        returns (
            uint256 balance,
            uint256 createdAt,
            uint256 inactivityPeriod,
            uint256 lastCheckIn,
            uint256 releasableAt,
            bool releasable,
            Heir[] memory heirs_
        )
    {
        Will storage w = wills[testator];
        return (
            w.balance,
            w.createdAt,
            w.inactivityPeriod,
            w.lastCheckIn,
            w.lastCheckIn + w.inactivityPeriod,
            isReleasable(testator),
            w.heirs
        );
    }

    /// @notice Returns the tokens deposited into a will and their current balances.
    /// @param testator Owner of the will.
    /// @return tokens Tokens listed in the will, including fully withdrawn ones.
    /// @return amounts Current balance of each token, in the same order.
    function getWillTokens(address testator) external view returns (address[] memory tokens, uint256[] memory amounts) {
        Will storage w = wills[testator];
        tokens = w.depositedTokens;
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = tokenBalances[testator][tokens[i]];
        }
    }

    // ---- Internal helpers ----

    /// @dev Debits the caller's will and pays `to`. Resets the inactivity timer.
    /// @param to Address to pay.
    /// @param amount Amount to withdraw.
    function _withdrawNative(address to, uint256 amount) internal {
        Will storage w = wills[msg.sender];
        require(amount > 0 && amount <= w.balance, "invalid amount");
        w.balance -= amount;
        w.lastCheckIn = block.timestamp;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "transfer failed");
        emit Withdrawn(msg.sender, amount, w.balance);
        if (to != msg.sender) emit PayoutRedirected(msg.sender, to, amount);
    }

    /// @dev Clears the credit of `from` and pays it to `to`.
    /// @param from Account whose credit is collected.
    /// @param to Address to pay.
    function _claimNative(address from, address to) internal {
        uint256 amount = claimable[from];
        require(amount > 0, "nothing to claim");
        claimable[from] = 0;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "transfer failed");
        emit Claimed(from, amount);
        if (to != from) emit PayoutRedirected(from, to, amount);
    }

    /// @dev Clears the token credit of `recipient` and pays it to the same address.
    /// @param token Token to collect.
    /// @param recipient Account whose credit is collected and paid.
    function _claimToken(address token, address recipient) internal {
        uint256 amount = claimableTokens[recipient][token];
        require(amount > 0, "nothing to claim");
        claimableTokens[recipient][token] = 0;
        totalClaimableTokens[token] -= amount;

        IERC20(token).safeTransfer(recipient, amount);
        emit TokenClaimed(recipient, token, amount);
    }

    /// @dev Rejects the zero address and this contract, from which funds could not be recovered.
    /// @param to Address to check.
    function _requireValidRecipient(address to) internal view {
        require(to != address(0) && to != address(this), "invalid recipient");
    }

    /// @dev Credits native coins by share. The last heir receives the remainder, so no dust is lost.
    /// @param testator Credited instead if there are no heirs.
    /// @param amount Amount to distribute.
    /// @param heirs_ Heirs and shares.
    function _distributeNative(address testator, uint256 amount, Heir[] memory heirs_) internal {
        if (heirs_.length == 0) {
            claimable[testator] += amount;
            return;
        }
        uint256 distributed = 0;
        for (uint256 i = 0; i < heirs_.length; i++) {
            uint256 share = (i == heirs_.length - 1)
                ? amount - distributed // last heir gets remainder to avoid rounding dust
                : (amount * heirs_[i].shareBps) / TOTAL_BPS;
            distributed += share;
            if (share > 0) claimable[heirs_[i].addr] += share;
        }
    }

    /// @dev Credits a token by share. The last heir receives the remainder, so no dust is lost.
    /// @param testator Credited instead if there are no heirs.
    /// @param token Token to distribute.
    /// @param amount Amount to distribute.
    /// @param heirs_ Heirs and shares.
    function _distributeToken(address testator, address token, uint256 amount, Heir[] memory heirs_) internal {
        if (heirs_.length == 0) {
            claimableTokens[testator][token] += amount;
            totalClaimableTokens[token] += amount;
            return;
        }
        uint256 distributed = 0;
        for (uint256 i = 0; i < heirs_.length; i++) {
            uint256 share = (i == heirs_.length - 1)
                ? amount - distributed
                : (amount * heirs_[i].shareBps) / TOTAL_BPS;
            distributed += share;
            if (share > 0) {
                claimableTokens[heirs_[i].addr][token] += share;
                totalClaimableTokens[token] += share;
            }
        }
    }

    /// @dev Splits a deposit according to FEE_BPS. The fee is rounded up, so any non-zero deposit
    ///      pays at least 1 unit and the fee cannot be avoided by splitting it into deposits below
    ///      TOTAL_BPS / FEE_BPS units.
    /// @param amount Deposit amount.
    /// @return fee Fee part.
    /// @return net Part credited to the will.
    function _splitFee(uint256 amount) internal pure returns (uint256 fee, uint256 net) {
        fee = Math.mulDiv(amount, FEE_BPS, TOTAL_BPS, Math.Rounding.Ceil);
        net = amount - fee;
    }

    /// @dev Adds a native coin fee to pendingFees. Nothing is sent here: see withdrawFees().
    /// @param fee Fee amount.
    function _accrueFee(uint256 fee) internal {
        if (fee == 0) return;
        pendingFees += fee;
    }

    /// @dev Converts an inactivity period to seconds.
    /// @param period Inactivity period.
    /// @return Duration in seconds.
    function _durationOf(InactivityPeriod period) internal pure returns (uint256) {
        if (period == InactivityPeriod.ThreeMonths) return 90 days;
        if (period == InactivityPeriod.SixMonths) return 180 days;
        return 365 days; // OneYear
    }

    /// @dev Reverts unless the list is empty, or has at most MAX_HEIRS unique valid addresses, none of
    ///      them this contract, with positive shares that add up to TOTAL_BPS.
    /// @param heirs_ Heirs and shares to validate.
    function _validateHeirs(Heir[] calldata heirs_) internal view {
        require(heirs_.length <= MAX_HEIRS, "too many heirs");
        if (heirs_.length == 0) return;
        uint256 sum = 0;
        for (uint256 i = 0; i < heirs_.length; i++) {
            require(heirs_[i].addr != address(0), "zero heir address");
            require(heirs_[i].addr != address(this), "heir is this contract");
            require(heirs_[i].shareBps > 0, "zero heir share");
            for (uint256 j = i + 1; j < heirs_.length; j++) {
                require(heirs_[i].addr != heirs_[j].addr, "duplicate heir address");
            }
            sum += heirs_[i].shareBps;
        }
        require(sum == TOTAL_BPS, "shares must sum to 10000");
    }
}
