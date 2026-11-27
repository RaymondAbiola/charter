// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/hooks/base/BaseHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {ProtocolFeeLibrary} from "v4-core/libraries/ProtocolFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Book, Lease, Guard, Bid, Env} from "./types/CharterTypes.sol";
import {PassiveMath} from "./libraries/PassiveMath.sol";
import {Positions} from "./libraries/Positions.sol";
import {VaultLogic} from "./libraries/VaultLogic.sol";
import {LeaseLogic} from "./libraries/LeaseLogic.sol";
import {LeaseMath} from "./libraries/LeaseMath.sol";
import {RiskLogic} from "./libraries/RiskLogic.sol";
import {ViewLogic} from "./libraries/ViewLogic.sol";

/// @title Charter
/// @notice Liquidity managers lease depositor capital in one Uniswap v4 pool. Depositors are owed
/// the passive full-range return plus rent; managers bond, run their own ranges and keep or cover
/// the difference.
/// @dev Shares are pro-rata claims on a bundle: units of full-range liquidity plus idle tokens.
/// Heavy flows live in external libraries called by delegatecall, so the hook stays the owner of
/// every position and the caller the PoolManager sees.
contract Charter is BaseHook, IUnlockCallback, ERC20 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;
    using ProtocolFeeLibrary for uint24;

    enum Action {
        Deposit,
        Withdraw,
        Open,
        Rebalance,
        Liquidate,
        Repassivate,
        Exit,
        Bid,
        Activate,
        Cancel
    }

    struct Config {
        Currency currency0;
        Currency currency1;
        int24 tickSpacing;
        uint24 baseFee;
        uint16 clampSqrtBps;
        uint8 maxLeases;
        uint16 minBondBps;
        uint16 maintenanceBps;
        uint32 auctionDelay;
        uint16 minRaiseBps;
        uint16 shareCapBps;
    }

    uint256 internal constant Q128 = 1 << 128;
    uint256 public constant DEAD_SHARES = 1000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // transient snapshot taken in beforeSwap
    uint256 internal constant T_FG0 = uint256(keccak256("charter.fg0")) - 1;
    uint256 internal constant T_FG1 = uint256(keccak256("charter.fg1")) - 1;
    uint256 internal constant T_SQRT = uint256(keccak256("charter.sqrt")) - 1;

    Currency public immutable currency0;
    Currency public immutable currency1;
    int24 public immutable tickSpacing;
    uint24 public immutable baseFee;
    uint16 public immutable clampSqrtBps;
    uint8 public immutable maxLeases;
    uint16 public immutable minBondBps;
    uint16 public immutable maintenanceBps;
    uint32 public immutable auctionDelay;
    uint16 public immutable minRaiseBps;
    uint16 public immutable shareCapBps;
    int24 public immutable fullLower;
    int24 public immutable fullUpper;

    PoolKey internal _key;
    PoolId public poolId;
    bool public bound;

    uint64 public lastSwapBlock;
    uint160 public blockStartSqrt;

    Book internal _book;
    mapping(uint256 slot => Lease) internal _leases;
    mapping(uint256 slot => Guard) internal _guards;
    mapping(uint256 slot => Bid) internal _bids;

    error WrongPool();
    error AlreadyBound();
    error NotBound();
    error BadConfig();
    error ZeroShares();
    error Slippage();
    error BadSlot();
    error SlotTaken();
    error NotManager();
    error BadRange();
    error NotEnoughCapital();
    error BondTooSmall();
    error NoLease();
    error Healthy();
    error NotReady();
    error BidTooLow();
    error NoBid();
    error ShareCapExceeded();

    event Bound(PoolId indexed id, uint160 sqrtPriceX96);
    event Deposit(address indexed payer, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdraw(address indexed owner, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event LeaseOpened(
        uint256 indexed slot,
        address indexed manager,
        uint128 units,
        uint32 rentPips,
        uint256 bond,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );
    event Rebalanced(uint256 indexed slot, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event RentPaid(uint256 indexed slot, uint256 amount);
    event Liquidated(
        uint256 indexed slot,
        address indexed manager,
        uint256 owedValue,
        uint256 heldValue,
        uint256 bondUsed,
        uint256 uncovered
    );
    event Repassivated(uint128 liquidity);
    event BidPlaced(
        uint256 indexed slot,
        address indexed bidder,
        uint128 units,
        uint32 rentPips,
        uint256 bond,
        int24 tickLower,
        int24 tickUpper,
        uint64 readyAt
    );
    event BidRefunded(uint256 indexed slot, address indexed bidder, uint256 bond);
    event BidVoided(uint256 indexed slot, address indexed bidder);
    event TakenOver(uint256 indexed slot, address indexed from, address indexed to);
    event LeaseEnded(
        uint256 indexed slot,
        address indexed manager,
        uint256 owedValue,
        uint256 heldValue,
        uint256 bondUsed,
        uint256 uncovered,
        uint256 toManager0,
        uint256 toManager1
    );

    constructor(IPoolManager manager, Config memory cfg) BaseHook(manager) ERC20("Charter LP", "CHARTER-LP") {
        // native currency would need payable flows; not supported yet
        if (cfg.currency0.isAddressZero()) revert BadConfig();
        if (Currency.unwrap(cfg.currency0) >= Currency.unwrap(cfg.currency1)) revert BadConfig();
        if (cfg.baseFee > LPFeeLibrary.MAX_LP_FEE || cfg.clampSqrtBps == 0 || cfg.clampSqrtBps >= 10_000) {
            revert BadConfig();
        }
        if (cfg.maxLeases == 0 || cfg.maxLeases > 16 || cfg.minBondBps == 0 || cfg.minBondBps > 10_000) {
            revert BadConfig();
        }
        // the bond must leave room above the maintenance margin
        if (cfg.maintenanceBps == 0 || cfg.maintenanceBps >= cfg.minBondBps) revert BadConfig();
        if (cfg.minRaiseBps == 0 || cfg.shareCapBps == 0 || cfg.shareCapBps > 10_000) revert BadConfig();
        currency0 = cfg.currency0;
        currency1 = cfg.currency1;
        tickSpacing = cfg.tickSpacing;
        baseFee = cfg.baseFee;
        clampSqrtBps = cfg.clampSqrtBps;
        maxLeases = cfg.maxLeases;
        minBondBps = cfg.minBondBps;
        maintenanceBps = cfg.maintenanceBps;
        auctionDelay = cfg.auctionDelay;
        minRaiseBps = cfg.minRaiseBps;
        shareCapBps = cfg.shareCapBps;
        fullLower = TickMath.minUsableTick(cfg.tickSpacing);
        fullUpper = TickMath.maxUsableTick(cfg.tickSpacing);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    // ------------------------------------------------------------------ depositors

    /// @notice Mint `shares` by adding the matching slice of the vault's bundle.
    function deposit(uint256 shares, uint256 max0, uint256 max1, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (!bound) revert NotBound();
        if (shares == 0) revert ZeroShares();
        (amount0, amount1) = abi.decode(
            poolManager.unlock(abi.encode(Action.Deposit, abi.encode(msg.sender, shares, to))), (uint256, uint256)
        );
        if (amount0 > max0 || amount1 > max1) revert Slippage();
    }

    /// @notice Burn `shares` and receive the matching slice of the bundle.
    function withdraw(uint256 shares, uint256 min0, uint256 min1, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroShares();
        (amount0, amount1) = abi.decode(
            poolManager.unlock(abi.encode(Action.Withdraw, abi.encode(msg.sender, shares, to))), (uint256, uint256)
        );
        if (amount0 < min0 || amount1 < min1) revert Slippage();
    }

    // ------------------------------------------------------------------ managers

    /// @notice Lease `units` of depositor liquidity into `slot` and run it in `[tickLower, tickUpper)`.
    /// @param rentPips annual rent as millionths of the leased value
    /// @param bond token1 posted as security, at least `minBondBps` of the leased value
    function openLease(uint256 slot, uint128 units, uint32 rentPips, uint256 bond, int24 tickLower, int24 tickUpper)
        external
    {
        if (!bound) revert NotBound();
        if (slot >= maxLeases) revert BadSlot();
        _unlock(Action.Open, abi.encode(_order(slot, units, rentPips, bond, tickLower, tickUpper)));
    }

    function rebalance(uint256 slot, int24 tickLower, int24 tickUpper) external {
        if (_leases[slot].manager != msg.sender) revert NotManager();
        _unlock(Action.Rebalance, abi.encode(slot, tickLower, tickUpper));
    }

    /// @notice Bid to take over an occupied slot. Rent must beat both the current lease and any
    /// pending bid by `minRaiseBps`. The bond is escrowed now; an outbid bidder is refunded.
    /// After `auctionDelay`, anyone can activate the takeover.
    function bid(uint256 slot, uint128 units, uint32 rentPips, uint256 bond, int24 tickLower, int24 tickUpper)
        external
    {
        if (slot >= maxLeases) revert BadSlot();
        _unlock(Action.Bid, abi.encode(_order(slot, units, rentPips, bond, tickLower, tickUpper)));
    }

    /// @notice Hand a slot to its pending bid once the delay has passed. Only while the price sits at
    /// the block's opening price, so the hand-over price cannot have been pushed. Anyone can call it.
    function activate(uint256 slot) external {
        Bid storage b = _bids[slot];
        if (b.bidder == address(0)) revert NoBid();
        if (block.timestamp < b.readyAt || !_quiet()) revert NotReady();
        _unlock(Action.Activate, abi.encode(slot));
    }

    /// @notice Take back the escrow of your pending bid once it has been ready to activate but has
    /// not gone through.
    function cancelBid(uint256 slot) external {
        _unlock(Action.Cancel, abi.encode(slot, msg.sender));
    }

    /// @notice End your lease. It settles like a liquidation: rent first, liquidity pulled, then
    /// depositors take what they are owed at the clamped price and you keep the rest.
    function exitLease(uint256 slot) external {
        if (_leases[slot].manager != msg.sender) revert NotManager();
        _unlock(Action.Exit, abi.encode(slot));
    }

    /// @notice Close a lease whose equity is below the maintenance margin. Swaps already do this;
    /// this covers a lease whose bond was eaten by rent while nobody traded. Anyone can call it.
    function liquidate(uint256 slot) external {
        if (_leases[slot].manager == address(0)) revert NoLease();
        if (!_underwater(slot, _spot())) revert Healthy();
        _unlock(Action.Liquidate, abi.encode(slot));
    }

    /// @notice Put idle depositor tokens back to full range. Only while the price sits at the block's
    /// opening price, so it cannot add liquidity at a price pushed in the same block.
    function repassivate() external {
        if (!bound || !_quiet()) revert NotReady();
        _unlock(Action.Repassivate, "");
    }

    /// @notice Pay a lease's accrued rent from its bond to depositors. Anyone can call it.
    function collectRent(uint256 slot) external returns (uint256) {
        return LeaseLogic.chargeRent(_book, _leases[slot], _guards[slot], _env(), slot, settlementSqrtPrice());
    }

    function _order(uint256 slot, uint128 units, uint32 rentPips, uint256 bond, int24 lo, int24 hi)
        internal
        view
        returns (LeaseLogic.Order memory)
    {
        return LeaseLogic.Order({
            manager: msg.sender,
            slot: slot,
            units: units,
            rentPips: rentPips,
            bond: bond,
            tickLower: lo,
            tickUpper: hi,
            fromEscrow: false
        });
    }

    function _rules() internal view returns (LeaseLogic.Rules memory) {
        return LeaseLogic.Rules({
            settleSqrt: settlementSqrtPrice(),
            minBondBps: minBondBps,
            minRaiseBps: minRaiseBps,
            auctionDelay: auctionDelay,
            shareCapBps: shareCapBps
        });
    }

    /// @dev True when no swap this block has moved the price more than a tenth of the clamp from
    /// where the block opened. A dust swap cannot stall anything; a real push still can.
    function _quiet() internal view returns (bool) {
        if (lastSwapBlock != block.number) return true;
        uint256 open = blockStartSqrt;
        uint256 spot = _spot();
        uint256 gap = spot > open ? spot - open : open - spot;
        return gap * 100_000 <= open * clampSqrtBps;
    }

    function _unlock(Action action, bytes memory args) internal returns (bytes memory) {
        return poolManager.unlock(abi.encode(action, args));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, bytes memory args) = abi.decode(data, (Action, bytes));
        if (action == Action.Deposit) return _deposit(args);
        if (action == Action.Withdraw) return _withdraw(args);
        if (action == Action.Open || action == Action.Bid) {
            LeaseLogic.Order memory o = abi.decode(args, (LeaseLogic.Order));
            if (action == Action.Open) LeaseLogic.open(_book, _leases[o.slot], _guards[o.slot], _env(), _rules(), o);
            else LeaseLogic.bid(_book, _leases[o.slot], _bids[o.slot], _env(), _rules(), o);
        } else if (action == Action.Rebalance) {
            (uint256 slot, int24 lo, int24 hi) = abi.decode(args, (uint256, int24, int24));
            LeaseLogic.rebalance(_book, _leases[slot], _guards[slot], _env(), _rules(), slot, lo, hi);
        } else if (action == Action.Repassivate) {
            LeaseLogic.repassivate(_book, _env());
        } else if (action == Action.Cancel) {
            (uint256 slot, address caller) = abi.decode(args, (uint256, address));
            LeaseLogic.cancelBid(_book, _bids[slot], _env(), slot, caller);
        } else {
            uint256 slot = abi.decode(args, (uint256));
            if (action == Action.Liquidate) {
                RiskLogic.liquidate(_book, _leases[slot], _env(), slot, settlementSqrtPrice());
                delete _guards[slot];
            } else if (action == Action.Exit) {
                LeaseLogic.exit(_book, _leases[slot], _guards[slot], _env(), slot, settlementSqrtPrice());
            } else {
                LeaseLogic.activate(_book, _leases[slot], _bids[slot], _guards[slot], _env(), _rules(), slot);
            }
        }
        return "";
    }

    function _deposit(bytes memory args) internal returns (bytes memory) {
        (address payer, uint256 shares, address to) = abi.decode(args, (address, uint256, address));
        uint256 supply = totalSupply();
        (uint256 r0, uint256 r1) = _settleLeases();
        (uint256 amount0, uint256 amount1) =
            VaultLogic.deposit(_book, _env(), payer, shares, supply, DEAD_SHARES, r0, r1);
        if (supply == 0) {
            _mint(DEAD, DEAD_SHARES);
            _mint(to, shares - DEAD_SHARES);
        } else {
            _mint(to, shares);
        }
        emit Deposit(payer, to, shares, amount0, amount1);
        return abi.encode(amount0, amount1);
    }

    function _withdraw(bytes memory args) internal returns (bytes memory) {
        (address owner, uint256 shares, address to) = abi.decode(args, (address, uint256, address));
        uint256 supply = totalSupply();
        _burn(owner, shares);
        (uint256 r0, uint256 r1) = _settleLeases();
        (uint256 out0, uint256 out1) =
            VaultLogic.withdraw(_book, _env(), to, shares, supply, r0, r1, settlementSqrtPrice());
        emit Withdraw(owner, to, shares, out0, out1);
        return abi.encode(out0, out1);
    }

    /// @dev Pays leases' rent and what fee debt they can cover before depositors come or go, and
    /// returns the fee debt still owed so share maths can count it.
    function _settleLeases() internal returns (uint256 r0, uint256 r1) {
        if (_book.leasedUnits == 0) return (0, 0);
        return LeaseLogic.settleAll(_book, _leases, _env(), maxLeases, settlementSqrtPrice());
    }

    function _underwater(uint256 slot, uint160 sqrtP) internal view returns (bool) {
        return RiskLogic.underwater(_book, _leases[slot], _env(), slot, sqrtP, maintenanceBps);
    }

    function _checkLeases() internal {
        RiskLogic.check(
            _book,
            _leases,
            _guards,
            _env(),
            RiskLogic.Params({maxLeases: maxLeases, maintenanceBps: maintenanceBps, settleSqrt: settlementSqrtPrice()})
        );
    }

    /// @notice Budgets left by a lease's last full check. Swaps skip the lease while all three hold.
    function guard(uint256 slot) external view returns (Guard memory) {
        return _guards[slot];
    }

    function _env() internal view returns (Env memory) {
        return Env({pm: poolManager, key: _key, fullLower: fullLower, fullUpper: fullUpper});
    }

    // ------------------------------------------------------------------ views

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function passiveLiquidity() external view returns (uint128) {
        return _book.passiveLiquidity;
    }

    function leasedUnits() external view returns (uint128) {
        return _book.leasedUnits;
    }

    function idle0() external view returns (uint256) {
        return _book.idle0;
    }

    function idle1() external view returns (uint256) {
        return _book.idle1;
    }

    function totalHeld0() external view returns (uint256) {
        return _book.totalHeld0;
    }

    function totalHeld1() external view returns (uint256) {
        return _book.totalHeld1;
    }

    function totalBond() external view returns (uint256) {
        return _book.totalBond;
    }

    /// @notice Value (token1) owed to depositors on closed leases that neither the lease nor its bond covered.
    function uncovered() external view returns (uint256) {
        return _book.uncovered;
    }

    /// @notice Fees one unit of depositor liquidity would have earned at full range, Q128, wrapping
    /// like the pool's own fee growth. A lease owes the growth of these over its life.
    function passiveGrowth0X128() external view returns (uint256) {
        return _book.passiveGrowth0X128;
    }

    function passiveGrowth1X128() external view returns (uint256) {
        return _book.passiveGrowth1X128;
    }

    /// @notice Sum of every lease's position liquidity, measured against the share cap.
    function managedLiquidity() external view returns (uint256) {
        return _book.managedLiquidity;
    }

    function totalEscrow() external view returns (uint256) {
        return _book.totalEscrow;
    }

    function pendingBid(uint256 slot) external view returns (Bid memory) {
        return _bids[slot];
    }

    function lease(uint256 slot) external view returns (Lease memory) {
        return _leases[slot];
    }

    /// @notice A lease's books at the settlement price: what it owes depositors, what it holds,
    /// and the equity left once its bond and unpaid rent are counted. Values are in token1.
    function leaseAccount(uint256 slot)
        external
        view
        returns (LeaseMath.Account memory a, uint256 bond, uint256 rent, int256 equity)
    {
        return ViewLogic.leaseAccount(_book, _leases[slot], _env(), slot, settlementSqrtPrice());
    }

    /// @notice Rent a lease has accrued and not yet paid, in token1.
    function rentDue(uint256 slot) external view returns (uint256) {
        return ViewLogic.rentDue(_leases[slot], _env(), settlementSqrtPrice());
    }

    /// @notice What depositors collectively own right now: full-range liquidity units plus idle tokens,
    /// counting fees the passive position has earned but not yet collected.
    function bundle() external view returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        return ViewLogic.bundle(_book, _leases, _env(), maxLeases, settlementSqrtPrice());
    }

    function previewDeposit(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        return ViewLogic.previewDeposit(_book, _leases, _env(), maxLeases, settlementSqrtPrice(), shares, totalSupply());
    }

    function previewWithdraw(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        return
            ViewLogic.previewWithdraw(_book, _leases, _env(), maxLeases, settlementSqrtPrice(), shares, totalSupply());
    }

    /// @notice Smallest bond for leasing `units`: `minBondBps` of their full-range value at the settlement price.
    function minBond(uint128 units) public view returns (uint256) {
        return ViewLogic.minBond(_env(), units, settlementSqrtPrice(), minBondBps);
    }

    /// @notice Spot clamped to the block's opening price, so a price pushed inside the current
    /// block cannot move a settlement by more than the clamp.
    function settlementSqrtPrice() public view returns (uint160) {
        uint160 spot = _spot();
        if (lastSwapBlock != block.number) return spot;
        uint256 lo = uint256(blockStartSqrt) * (10_000 - clampSqrtBps) / 10_000;
        uint256 hi = uint256(blockStartSqrt) * (10_000 + clampSqrtBps) / 10_000;
        if (spot < lo) return uint160(lo);
        if (spot > hi) return uint160(hi);
        return spot;
    }

    function _spot() internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = poolManager.getSlot0(poolId);
    }

    // ------------------------------------------------------------------ hook callbacks

    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96) internal override returns (bytes4) {
        if (bound) revert AlreadyBound();
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(currency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(currency1) || key.tickSpacing != tickSpacing
                || !key.fee.isDynamicFee()
        ) revert WrongPool();
        _key = key;
        poolId = key.toId();
        bound = true;
        emit Bound(poolId, sqrtPriceX96);
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint160 sqrtP = _spot();
        if (lastSwapBlock != block.number) {
            lastSwapBlock = uint64(block.number);
            blockStartSqrt = sqrtP;
        }
        if (_book.passiveLiquidity + _book.leasedUnits != 0) {
            (uint256 fg0, uint256 fg1) = poolManager.getFeeGrowthGlobals(poolId);
            uint256 t0 = T_FG0;
            uint256 t1 = T_FG1;
            uint256 ts = T_SQRT;
            assembly ("memory-safe") {
                tstore(t0, fg0)
                tstore(t1, fg1)
                tstore(ts, sqrtP)
            }
        }
        return
            (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, baseFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (_book.passiveLiquidity + _book.leasedUnits != 0) _accruePassive(params.zeroForOne, delta);
        if (_book.leasedUnits != 0) _checkLeases();
        return (BaseHook.afterSwap.selector, 0);
    }

    function _accruePassive(bool zeroForOne, BalanceDelta delta) internal {
        uint256 fgBefore;
        uint256 sqrtBefore;
        uint256 slot = zeroForOne ? T_FG0 : T_FG1;
        uint256 ts = T_SQRT;
        assembly ("memory-safe") {
            fgBefore := tload(slot)
            sqrtBefore := tload(ts)
        }
        (uint256 fg0, uint256 fg1) = poolManager.getFeeGrowthGlobals(poolId);
        uint256 dfg;
        unchecked {
            dfg = (zeroForOne ? fg0 : fg1) - fgBefore;
        }
        if (dfg == 0) return;

        uint128 passive = _book.passiveLiquidity;
        uint128 leased = _book.leasedUnits;
        uint256 g;
        if (leased == 0) {
            // with nothing leased the counterfactual is what actually happened
            g = dfg;
        } else {
            int128 paid = zeroForOne ? delta.amount0() : delta.amount1();
            if (paid >= 0) return;
            (uint160 sqrtAfter,, uint24 protocolFee,) = poolManager.getSlot0(poolId);
            uint16 pf = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
            uint256 fee = PassiveMath.lpFee(uint128(-paid), baseFee, pf);
            g = PassiveMath.growth(
                fee, dfg, _managedInRange(uint160(sqrtBefore), sqrtAfter), passive, uint256(passive) + leased
            );
        }
        unchecked {
            if (zeroForOne) _book.passiveGrowth0X128 += g;
            else _book.passiveGrowth1X128 += g;
        }
    }

    /// @dev Sum over leases of their liquidity weighted by how much of the swap's path fell in range.
    function _managedInRange(uint160 sqrtBefore, uint160 sqrtAfter) internal view returns (uint256 managed) {
        for (uint256 slot; slot < maxLeases; ++slot) {
            Lease storage l = _leases[slot];
            uint128 liq = l.liquidity;
            if (liq == 0) continue;
            uint256 f = PassiveMath.overlap(
                sqrtBefore,
                sqrtAfter,
                TickMath.getSqrtPriceAtTick(l.tickLower),
                TickMath.getSqrtPriceAtTick(l.tickUpper)
            );
            managed += uint256(liq) * f / 1e18;
        }
    }
}
